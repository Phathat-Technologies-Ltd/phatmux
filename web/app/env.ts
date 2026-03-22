import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  server: {
    RESEND_API_KEY: z.string().min(1),
    PHATMUX_FEEDBACK_FROM_EMAIL: z.string().email(),
    PHATMUX_FEEDBACK_RATE_LIMIT_ID: z.string().min(1),
  },
  runtimeEnv: {
    RESEND_API_KEY: process.env.RESEND_API_KEY,
    PHATMUX_FEEDBACK_FROM_EMAIL: process.env.PHATMUX_FEEDBACK_FROM_EMAIL,
    PHATMUX_FEEDBACK_RATE_LIMIT_ID: process.env.PHATMUX_FEEDBACK_RATE_LIMIT_ID,
  },
  skipValidation:
    process.env.SKIP_ENV_VALIDATION === "1" ||
    process.env.VERCEL_ENV === "preview",
});
