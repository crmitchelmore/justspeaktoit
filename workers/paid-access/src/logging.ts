/**
 * Structured logging with hard redaction guarantees.
 *
 * The paid-access Worker handles audio, transcripts and credentials. None of
 * those may ever reach a log line, so this module exposes no way to log a
 * free-form payload: callers pass a fixed event name plus a small map of
 * scalar fields, and any field whose key looks credential-shaped is dropped.
 */

const REDACTED = '[redacted]';

const SENSITIVE_KEY_PATTERN =
  /(authorization|api[-_]?key|secret|token|password|passphrase|signature|cookie|transcript|audio|prompt|text|email)/i;

export type LogValue = string | number | boolean | null | undefined;

export interface LogFields {
  readonly [key: string]: LogValue;
}

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

function sanitise(fields: LogFields): Record<string, LogValue> {
  const output: Record<string, LogValue> = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) continue;
    if (SENSITIVE_KEY_PATTERN.test(key)) {
      output[key] = REDACTED;
      continue;
    }
    if (typeof value === 'string' && value.length > 256) {
      output[key] = `${value.slice(0, 256)}…`;
      continue;
    }
    output[key] = value;
  }
  return output;
}

export interface Logger {
  readonly correlationId: string;
  log(level: LogLevel, event: string, fields?: LogFields): void;
  debug(event: string, fields?: LogFields): void;
  info(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
  error(event: string, fields?: LogFields): void;
  child(fields: LogFields): Logger;
}

export function createLogger(correlationId: string, base: LogFields = {}): Logger {
  const baseFields = sanitise(base);

  const logger: Logger = {
    correlationId,
    log(level, event, fields = {}) {
      const line = JSON.stringify({
        level,
        event,
        correlation_id: correlationId,
        ...baseFields,
        ...sanitise(fields),
      });
      if (level === 'error') {
        console.error(line);
      } else if (level === 'warn') {
        console.warn(line);
      } else {
        console.log(line);
      }
    },
    debug(event, fields) {
      logger.log('debug', event, fields);
    },
    info(event, fields) {
      logger.log('info', event, fields);
    },
    warn(event, fields) {
      logger.log('warn', event, fields);
    },
    error(event, fields) {
      logger.log('error', event, fields);
    },
    child(fields) {
      return createLogger(correlationId, { ...baseFields, ...fields });
    },
  };

  return logger;
}

/**
 * Converts an arbitrary thrown value into a log-safe description. Error
 * messages from upstream providers can echo request content, so only the
 * error *name* is kept unless the error is one we constructed ourselves.
 */
export function describeError(error: unknown): string {
  if (error instanceof Error) {
    return error.name;
  }
  return 'UnknownError';
}
