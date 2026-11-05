// Bundled into www/js/ugos-sdk.js, so the frontend itself needs no build step.
import UGOSCore from "@ugreen-nas/core";
import cloudWindow from "@ugreen-nas/core/cloudWindow";

window.UgvmSdk = {
  init: () => UGOSCore.init(),
  getThirdToken: () => cloudWindow.useCapacity("getThirdToken"),
};
