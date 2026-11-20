export type ErrorCode =
  | 'validation_error'
  | 'invalid_credentials'
  | 'unauthorized'
  | 'forbidden'
  | 'not_found'
  | 'conflict'
  | 'conversation_not_found'
  | 'not_a_member'
  | 'unsupported_conversation_type'
  | 'invalid_token'
  | 'rate_limited'
  | 'not_an_admin'
  | 'group_full'
  | 'last_admin'
  | 'media_too_large'
  | 'unsupported_media_type'
  | 'internal_error';

const STATUS: Record<ErrorCode, number> = {
  validation_error: 422,
  invalid_credentials: 401,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  conversation_not_found: 404,
  not_a_member: 403,
  unsupported_conversation_type: 422,
  invalid_token: 401,
  rate_limited: 429,
  not_an_admin: 403,
  group_full: 409,
  last_admin: 409,
  media_too_large: 413,
  unsupported_media_type: 415,
  internal_error: 500,
};

export class ApiError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = 'ApiError';
  }

  get status(): number {
    return STATUS[this.code];
  }

  toBody() {
    return {
      error: {
        code: this.code,
        message: this.message,
        ...(this.details ? { details: this.details } : {}),
      },
    };
  }
}
