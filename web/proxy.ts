import { type NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";

const intlMiddleware = createMiddleware(routing);

export default function middleware(request: NextRequest) {
  const host = request.headers.get("host") ?? "";

  // 301 redirect phatmux.dev (and www.phatmux.dev) to phatmux.com, preserving path and query
  if (host === "phatmux.dev" || host === "www.phatmux.dev") {
    const url = new URL(request.url);
    url.host = "phatmux.com";
    url.protocol = "https:";
    return NextResponse.redirect(url.toString(), 301);
  }

  return intlMiddleware(request);
}

export const config = {
  matcher: ["/((?!api|_next|_vercel|.*\\..*).*)"],
};
