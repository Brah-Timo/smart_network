import 'dart:math' as math;

/// Abstract contract for all delay-calculation strategies used between
/// retry attempts.
///
/// Implementations decide how long to wait before each retry,
/// allowing pluggable back-off behaviour without changing the retry logic.
abstract class BackoffStrategy {
  const BackoffStrategy();

  /// Returns the [Duration] to wait before attempt number [attemptNumber].
  ///
  /// [attemptNumber] is 0-based: the delay *before* the second attempt
  /// (i.e. after the first failure) uses `attemptNumber = 0`.
  Duration calculate(int attemptNumber);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Constant Backoff
// ─────────────────────────────────────────────────────────────────────────────

/// Waits the same fixed [delay] before every retry attempt.
///
/// Use when the failure is expected to resolve quickly and uniformly,
/// e.g. a brief network blip.
///
/// Timeline example (delay = 2 s):
/// ```
/// attempt 1 → wait 2 s → attempt 2 → wait 2 s → attempt 3
/// ```
class ConstantBackoff extends BackoffStrategy {
  /// The fixed wait duration applied before every retry.
  final Duration delay;

  const ConstantBackoff({
    this.delay = const Duration(seconds: 2),
  });

  @override
  Duration calculate(int attemptNumber) => delay;

  @override
  String toString() => 'ConstantBackoff(delay: ${delay.inMilliseconds}ms)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Linear Backoff
// ─────────────────────────────────────────────────────────────────────────────

/// Increases the wait duration by a constant [step] with each attempt.
///
/// Formula: `delay = step * (attemptNumber + 1)`
///
/// Timeline example (step = 1 s):
/// ```
/// attempt 1 → wait 1 s → attempt 2 → wait 2 s → attempt 3 → wait 3 s
/// ```
class LinearBackoff extends BackoffStrategy {
  /// The amount added to the delay per attempt.
  final Duration step;

  /// Maximum delay cap (prevents indefinite growth).
  final Duration maxDelay;

  const LinearBackoff({
    this.step = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
  });

  @override
  Duration calculate(int attemptNumber) {
    final ms = step.inMilliseconds * (attemptNumber + 1);
    return Duration(
      milliseconds: ms.clamp(0, maxDelay.inMilliseconds),
    );
  }

  @override
  String toString() => 'LinearBackoff(step: ${step.inMilliseconds}ms, '
      'max: ${maxDelay.inMilliseconds}ms)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Exponential Backoff with Full Jitter  ← DEFAULT (recommended)
// ─────────────────────────────────────────────────────────────────────────────

/// Doubles the wait duration with each attempt and adds random jitter.
///
/// ### Formula
/// ```
/// delay(n) = min(base × 2ⁿ + jitter, maxDelay)
///
/// where:
///   n      = attemptNumber (0-based)
///   jitter ∈ [0, base × 2ⁿ × jitterFactor]   (uniform random)
/// ```
///
/// ### Why jitter?
/// Without jitter all clients that encounter the same transient error
/// retry in perfect synchrony, creating a thundering-herd that overwhelms
/// the server. Full jitter spreads retries uniformly over the window.
///
/// ### Timeline example (base = 1 s, maxDelay = 30 s, jitter enabled)
/// ```
/// attempt 0 → wait ~1–2 s
/// attempt 1 → wait ~2–4 s
/// attempt 2 → wait ~4–8 s
/// attempt 3 → wait ~8–16 s
/// attempt 4 → wait ~16–30 s  (capped)
/// ```
class ExponentialBackoff extends BackoffStrategy {
  /// Initial base delay (delay before first retry).
  final Duration base;

  /// Hard ceiling — no retry waits longer than this.
  final Duration maxDelay;

  /// Fraction of the base delay added as random jitter (default: 1.0 = 100%).
  ///
  /// - `0.0` — no jitter (pure exponential)
  /// - `0.5` — jitter up to 50 % of computed delay
  /// - `1.0` — full jitter (recommended for distributed clients)
  final double jitterFactor;

  /// Random number generator — injectable for deterministic tests.
  final math.Random? random;

  const ExponentialBackoff({
    this.base = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.jitterFactor = 1.0,
    this.random,
  }) : assert(
          jitterFactor >= 0.0 && jitterFactor <= 1.0,
          'jitterFactor must be in [0.0, 1.0]',
        );

  @override
  Duration calculate(int attemptNumber) {
    final rng = random ?? math.Random();

    // Exponential component: base × 2^attempt (capped to avoid int overflow)
    final exponent = math.min(attemptNumber, 30); // 2^30 ≈ 1 billion ms
    final exponentialMs = base.inMilliseconds * (1 << exponent);

    // Jitter: uniform random in [0, exponentialMs × jitterFactor]
    final jitterCap = (exponentialMs * jitterFactor).round();
    final jitterMs = jitterCap > 0 ? rng.nextInt(jitterCap) : 0;

    final totalMs = (exponentialMs + jitterMs).clamp(
      base.inMilliseconds,
      maxDelay.inMilliseconds,
    );

    return Duration(milliseconds: totalMs);
  }

  @override
  String toString() => 'ExponentialBackoff('
      'base: ${base.inMilliseconds}ms, '
      'max: ${maxDelay.inMilliseconds}ms, '
      'jitter: ${(jitterFactor * 100).round()}%)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Decorrelated Jitter (AWS-style)
// ─────────────────────────────────────────────────────────────────────────────

/// Implements the "decorrelated jitter" algorithm from the AWS blog:
/// https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
///
/// ### Formula
/// ```
/// sleep(n) = min(cap, random_between(base, sleep(n−1) × 3))
/// ```
///
/// This produces a wider spread than full-jitter and is considered optimal
/// when many clients retry against the same endpoint simultaneously.
class DecorrelatedJitterBackoff extends BackoffStrategy {
  final Duration base;
  final Duration maxDelay;
  final math.Random? random;

  const DecorrelatedJitterBackoff({
    this.base = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.random,
  });

  @override
  Duration calculate(int attemptNumber) {
    final rng = random ?? math.Random();

    // Approximate the recurrence with a simple formula when state-less.
    // Previous sleep ≈ base × 1.5^attempt (geometric growth)
    final prevMs = (base.inMilliseconds *
            math.pow(1.5, attemptNumber.clamp(0, 20)))
        .round();

    final lo = base.inMilliseconds;
    final hi = (prevMs * 3).clamp(lo + 1, maxDelay.inMilliseconds);

    final ms = lo + rng.nextInt(hi - lo);
    return Duration(milliseconds: ms.clamp(lo, maxDelay.inMilliseconds));
  }

  @override
  String toString() => 'DecorrelatedJitterBackoff('
      'base: ${base.inMilliseconds}ms, '
      'max: ${maxDelay.inMilliseconds}ms)';
}
