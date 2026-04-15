import 'package:meta/meta.dart';

@immutable
sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T unwrap() => switch (this) {
        Ok<T, E>(value: final v) => v,
        Err<T, E>(error: final e) => throw StateError('Result.unwrap on Err: $e'),
      };

  R fold<R>(R Function(T) onOk, R Function(E) onErr) => switch (this) {
        Ok<T, E>(value: final v) => onOk(v),
        Err<T, E>(error: final e) => onErr(e),
      };
}

final class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);
  final T value;
}

final class Err<T, E> extends Result<T, E> {
  const Err(this.error);
  final E error;
}
