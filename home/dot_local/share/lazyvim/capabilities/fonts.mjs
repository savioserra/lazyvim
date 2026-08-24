import { defineCapability } from "./contract.mjs";

export default defineCapability({
  id: "fonts",
  requires: ["foundation"],
  setup({ platform }) {
    platform.configureFonts();
  },
  verify({ platform }) {
    platform.verifyFonts();
  },
});
