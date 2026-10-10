@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app

import com.yunx.app.ui.login.isLoginHost
import kotlinx.serialization.json.*
import platform.Foundation.*
import platform.WebKit.*
import platform.darwin.NSObject

/** Only compiled for the simulator. Commands contain one SMS code, never URLs or executable code. */
internal fun configureQuarkSmsTest(configuration: WKWebViewConfiguration) {
    val phone = NSProcessInfo.processInfo.environment["YUNX_QUARK_PHONE"] as? String ?: return
    if (!phone.matches(Regex("[0-9]{11}"))) return
    val handler = object : NSObject(), WKScriptMessageHandlerWithReplyProtocol {
        override fun userContentController(userContentController: WKUserContentController,
            didReceiveScriptMessage: WKScriptMessage, replyHandler: (Any?, String?) -> Unit) {
            val url = didReceiveScriptMessage.frameInfo.request.URL
            if (url?.scheme != "https" || !isLoginHost(url.host.orEmpty(), listOf("quark.cn"))) {
                replyHandler(null, "Unsupported login frame")
                return
            }
            val stage = didReceiveScriptMessage.body as? String
            if (stage in setOf("sms_sent", "sms_request_clicked", "sms_submit_clicked", "sms_challenge", "sms_error")) {
                (buildJsonObject { put("stage", stage) }.toString() as NSString).writeToFile(
                    NSHomeDirectory() + "/Documents/quark-login-ui.json", true, NSUTF8StringEncoding, null)
            }
            val raw = NSString.stringWithContentsOfFile(NSHomeDirectory() + "/Documents/quark-login-command.json", NSUTF8StringEncoding, null)
            val code = raw?.let { runCatching { Json.parseToJsonElement(it).jsonObject["code"]?.jsonPrimitive?.content }.getOrNull() }
                ?.takeIf { it.matches(Regex("[0-9]{4,8}")) }
            replyHandler(buildJsonObject { put("phone", phone); code?.let { put("code", it) } }.toString(), null)
        }
    }
    configuration.userContentController.addScriptMessageHandlerWithReply(handler, WKContentWorld.pageWorld, "yunxQuarkTest")
    configuration.userContentController.addUserScript(WKUserScript(source = """
        (() => {
          let stage = 'ready', requested = false, submitted = '';
          function setInput(input, value) {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
            input.dispatchEvent(new Event('input', {bubbles:true}));
            input.dispatchEvent(new Event('change', {bubbles:true}));
            input.style.webkitTextSecurity = 'disc';
          }
          async function tick() {
            try {
              const command = JSON.parse(await window.webkit.messageHandlers.yunxQuarkTest.postMessage(stage));
              const phone = document.getElementById('login_name');
              if (!phone) {
                const entry = Array.from(document.querySelectorAll('span,a,div')).find(e =>
                  e.textContent.trim() === '手机登录' && e.getBoundingClientRect().height > 0);
                if (entry) entry.click();
              } else {
                if (phone.value !== command.phone) setInput(phone, command.phone);
                if (!requested) {
                  const send = document.getElementById('send_sms_btn');
                  if (send) { requested = true; send.click(); stage = 'sms_request_clicked'; }
                }
                if (/\d/.test(document.getElementById('count_down')?.textContent || '')) stage = 'sms_sent';
                const challenge = document.querySelector('.aliyun-captcha-modal,.nc-container');
                if (challenge && challenge.getBoundingClientRect().height > 0) stage = 'sms_challenge';
                if (document.getElementById('message')?.textContent.trim()) stage = 'sms_error';
                const code = document.getElementById('sms_code');
                if (code && command.code && submitted !== command.code) {
                  setInput(code, command.code); submitted = command.code;
                  document.getElementById('submit_btn')?.click(); stage = 'sms_submit_clicked';
                }
              }
            } catch (_) {}
            setTimeout(tick, 1000);
          }
          tick();
        })();
    """.trimIndent(), injectionTime = WKUserScriptInjectionTime.WKUserScriptInjectionTimeAtDocumentEnd, forMainFrameOnly = false))
}
