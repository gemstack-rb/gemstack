"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { ApiError } from "@/lib/gemstack/client";

// Server state lives in TanStack Query; local UI state is plain React state;
// URL state uses Next.js search params. No global store is needed by default.
export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 30_000,
            // Don't retry requests the API rejected (4xx); retry transient failures twice.
            retry: (failureCount, error) => !(error instanceof ApiError && error.isClientError) && failureCount < 2,
          },
        },
      }),
  );

  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}
