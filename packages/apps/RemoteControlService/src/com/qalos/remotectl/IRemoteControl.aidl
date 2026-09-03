/* SPDX-License-Identifier: Apache-2.0
 *
 * qalos — Remote Control Service AIDL interface.
 *
 * This AIDL is internal to the framework. It is not exposed across the
 * AIDL-stable boundary; the only caller is the embedded HttpApiServer
 * inside the same service. External clients use the HTTP/JSON API
 * documented in website/docs/qa-lab-os/api.md.
 */

package com.qalos.remotectl;

interface IRemoteControl {
    // --- Input ---
    void tap(int x, int y, int displayId);
    void typeText(String text);
    void keyEvent(int keyCode, boolean down);

    // --- App lifecycle ---
    void launchApp(String packageName);
    void forceStop(String packageName);

    // --- Queries ---
    String getForegroundPackage();
    int getDisplayWidth(int displayId);
    int getDisplayHeight(int displayId);

    // --- Screenshot (returns a base64-encoded PNG so the HTTP layer
    //     does not need to encode it again). ---
    String screenshotBase64(int width, int height, int displayId, int quality);
}
