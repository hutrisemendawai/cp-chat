import { diag, DiagConsoleLogger, DiagLogLevel, SpanKind, trace, type Span } from '@opentelemetry/api';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { resourceFromAttributes } from '@opentelemetry/resources';
import {
  BatchSpanProcessor,
  NodeTracerProvider,
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
} from '@opentelemetry/sdk-trace-node';
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from '@opentelemetry/semantic-conventions';

import type { Config } from '../config.js';

export type Tracing = {
  shutdown: () => Promise<void>;
};

let provider: NodeTracerProvider | null = null;

/**
 * OpenTelemetry tracing for the REST server and the gateway.
 *
 * Disabled by default (`OTEL_ENABLED=false`) so local development and tests do
 * not need a collector. When enabled, HTTP and Fastify spans are exported over
 * OTLP/HTTP. Pino logs stay separate; the important thing for incident
 * response is that one trace spans REST -> gateway -> broker -> recipient.
 *
 * Head sampling is parent-based: a child process (the gateway consuming a
 * broker event) honours the sampler ratio only when it starts a root span, so a
 * trace started at the REST edge is kept end-to-end.
 */
export async function startTracing(
  config: Config,
  service: 'rest' | 'gateway',
): Promise<Tracing | null> {
  if (!config.OTEL_ENABLED) return null;

  if (config.NODE_ENV === 'development') {
    diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.WARN);
  }

  const exporter = new OTLPTraceExporter({ url: `${config.OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces` });
  provider = new NodeTracerProvider({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: `${config.OTEL_SERVICE_NAME}-${service}`,
      [ATTR_SERVICE_VERSION]: '0.4.0',
      'deployment.node_id': config.gatewayNodeId,
    }),
    sampler: new ParentBasedSampler({
      root: new TraceIdRatioBasedSampler(config.OTEL_TRACES_SAMPLER_RATIO),
    }),
    spanProcessors: [new BatchSpanProcessor(exporter)],
  });
  provider.register();

  registerInstrumentations({
    instrumentations: [
      // HTTP spans cover every Fastify request (Fastify rides on node:http);
      // route-level detail is added by withSpan() around the work that matters.
      new HttpInstrumentation({
        // Health checks are noise at this volume.
        ignoreIncomingRequestHook: (request) =>
          request.url === '/healthz' || request.url === '/readyz',
      }),
    ],
  });

  return {
    shutdown: async () => {
      await provider?.shutdown().catch(() => undefined);
      provider = null;
    },
  };
}

export async function shutdownTracing(): Promise<void> {
  await provider?.shutdown().catch(() => undefined);
  provider = null;
}

/**
 * Wraps a unit of work in a span. Used around broker consumption and message
 * processing, which are not HTTP requests and so are not auto-instrumented.
 */
export async function withSpan<T>(
  name: string,
  attributes: Record<string, string | number | boolean | undefined>,
  fn: (span: Span) => Promise<T>,
): Promise<T> {
  const tracer = trace.getTracer('cp-chat');
  return tracer.startActiveSpan(
    name,
    { kind: SpanKind.INTERNAL, attributes: prune(attributes) },
    async (span) => {
      try {
        return await fn(span);
      } catch (error) {
        span.recordException(error as Error);
        span.setStatus({ code: 2, message: (error as Error).message });
        throw error;
      } finally {
        span.end();
      }
    },
  );
}

function prune(
  attributes: Record<string, string | number | boolean | undefined>,
): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}
