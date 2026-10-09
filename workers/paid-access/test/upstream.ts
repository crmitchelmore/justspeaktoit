import { expect, vi } from 'vitest';

const upstreamFetch = vi.fn<typeof fetch>();
let expectedCalls = 0;

export function installUpstreamMock(): void {
  expectedCalls = 0;
  upstreamFetch.mockReset();
  upstreamFetch.mockImplementation(() => {
    throw new Error('Unexpected upstream request: real network access is disabled in tests.');
  });
  vi.stubGlobal('fetch', upstreamFetch);
}

export function mockOpenRouterResponse(
  body: object | string | (() => object),
  status = 200,
  checkRequest?: (request: Request) => Promise<void>,
): void {
  expectedCalls += 1;
  upstreamFetch.mockImplementationOnce(async (input, init) => {
    const request = new Request(input, init);
    expect(request.url).toBe('https://openrouter.ai/api/v1/chat/completions');
    expect(request.method).toBe('POST');
    await checkRequest?.(request);
    const data = typeof body === 'function' ? body() : body;
    return new Response(typeof data === 'string' ? data : JSON.stringify(data), { status });
  });
}

export function verifyUpstreamMock(): void {
  expect(upstreamFetch).toHaveBeenCalledTimes(expectedCalls);
  for (const result of upstreamFetch.mock.settledResults) {
    expect(result.type).toBe('fulfilled');
  }
}
