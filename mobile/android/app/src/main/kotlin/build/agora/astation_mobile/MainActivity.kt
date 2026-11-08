package build.agora.astation_mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import uniffi.atem_client_ffi.uniffiEnsureInitialized

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
    private var events: EventChannel.EventSink? = null
    private var contextId = UUID.randomUUID().toString()
    private var revision = 0L
    private var environment = "production"
    private var developmentBuild = false
    private val accountScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var account: MobileAccountAuth? = null
    private var loginResult: MethodChannel.Result? = null
    private var notice: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        uniffiEnsureInitialized()
        developmentBuild = applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        environment = if (developmentBuild) getPreferences(MODE_PRIVATE)
            .getString("environment", "development") ?: "development" else "production"
        account = MobileAccountAuth(this, MobileOAuthConfig(environment == "development"))
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "build.agora.astation/mobile.v1").setMethodCallHandler(::handle)
        EventChannel(messenger, "build.agora.astation/workspace.v1").setStreamHandler(this)
        val active = account!!
        accountScope.launch {
            try { active.restore() }
            catch (error: Exception) { if (account === active) notice = safeError(error) }
            if (account === active) publish(reset = true)
        }
    }

    private fun snapshot(): Map<String, Any?> = mapOf(
        "bridgeVersion" to 1, "context" to contextId, "revision" to revision,
        "environment" to environment, "account" to account?.subject?.let { mapOf("id" to it, "name" to "Agora.Build account") }, "access" to "notEnrolled",
        "deviceName" to Build.MODEL, "deviceId" to "", "loginAvailable" to (account != null),
        "enrollmentAvailable" to false,
        "hosts" to emptyList<Any>(), "agents" to emptyList<Any>(), "profiles" to emptyList<Any>(),
        "approvals" to emptyList<Any>(), "conversations" to emptyList<Any>(), "rules" to emptyList<Any>(),
        "notice" to (notice ?: "Verify this device before connecting to your agents.")
    )

    private fun publish(reset: Boolean = false) {
        if (reset) contextId = UUID.randomUUID().toString()
        revision++
        events?.success(snapshot())
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readState" -> result.success(snapshot())
            "refresh", "setForeground" -> {
                if (account?.subject == null || (call.method == "setForeground" && call.argument<Boolean>("foreground") != true)) result.success(null)
                else accountOperation(result) { it.refresh(); null }
            }
            "signIn" -> {
                if (loginResult != null) { result.error("busy", "Finish the current sign-in first.", null); return }
                loginResult = result
                val active = account ?: run { loginResult = null; result.error("unavailable", "Sign-in is unavailable.", null); return }
                accountScope.launch {
                    try {
                        val intent = active.signInIntent()
                        if (account !== active || loginResult !== result) throw MobileLoginFailure("changed")
                        startActivityForResult(intent, 4381)
                    }
                    catch (error: Exception) {
                        if (loginResult === result) {
                            active.cancelSignIn()
                            loginResult = null
                            result.error("account_error", safeError(error), null)
                        }
                    }
                }
            }
            "signOut" -> {
                cancelPendingLogin()
                accountOperation(result, reset = true) { it.signOut(); null }
            }
            "verifyLogin" -> {
                if (!developmentBuild) result.notImplemented()
                else accountOperation(result) { it.verifyLogin() }
            }
            "selectEnvironment" -> {
                val selected = call.argument<String>("environment")
                if (!developmentBuild || selected !in listOf("development", "production")) {
                    result.error("invalid_environment", "Server selection is available in development builds.", null)
                    return
                }
                cancelPendingLogin()
                accountOperation(result, reset = true) {
                    it.signOut(); it.dispose()
                    environment = selected!!
                    getPreferences(MODE_PRIVATE).edit().putString("environment", environment).apply()
                    account = MobileAccountAuth(this, MobileOAuthConfig(environment == "development"))
                    null
                }
            }
            "openExternal" -> {
                val uri = call.argument<String>("url")?.let(Uri::parse)
                if (uri == null || uri.scheme != "https" || uri.host.isNullOrEmpty() || uri.userInfo != null) {
                    result.error("invalid_url", "This link cannot be opened safely.", null)
                    return
                }
                try { startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(null) }
                catch (_: android.content.ActivityNotFoundException) {
                    result.error("browser_unavailable", "Install a browser to open this link.", null)
                }
            }
            "enrollDevice" -> result.error("enrollment_not_ready",
                "Device setup is not available in this build yet. Your account is signed in, but this phone cannot access agents until trusted-device enrollment is implemented.", null)
            else -> result.error("not_authenticated", "Sign in and verify this device before connecting to an Atem.", null)
        }
    }

    private fun accountOperation(result: MethodChannel.Result, reset: Boolean = false,
                                 operation: suspend (MobileAccountAuth) -> Any?) {
        val active = account ?: run { result.error("account_error", "Sign-in is unavailable.", null); return }
        accountScope.launch {
            try {
                val value = operation(active)
                notice = null; publish(reset); result.success(value)
            } catch (error: Exception) {
                if (account === active) { notice = safeError(error); publish() }
                result.error("account_error", safeError(error), null)
            }
        }
    }

    private fun safeError(error: Exception): String {
        if (developmentBuild) {
            val frame = error.stackTrace.firstOrNull { it.className.startsWith("build.agora.astation_mobile.") }
            // Exception messages and data can contain OAuth credentials; log only type and location.
            Log.w("AstationAccount", "Account failure: ${error.javaClass.simpleName} at ${frame?.methodName}:${frame?.lineNumber}")
        }
        return (error as? MobileLoginFailure)?.message
            ?: "The account operation could not be completed. Try signing in again."
    }

    private fun cancelPendingLogin() {
        loginResult?.error("cancelled", "Account sign-in was cancelled.", null)
        loginResult = null
    }

    @Deprecated("AppAuth callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4381) return
        val pending = loginResult ?: return
        loginResult = null
        accountOperation(pending, reset = true) { it.finishSignIn(if (resultCode == RESULT_OK) data else null); null }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink; sink.success(snapshot()) }
    override fun onCancel(arguments: Any?) { events = null }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        events = null
        account?.dispose(); account = null
        accountScope.cancel()
        loginResult?.error("cancelled", "Account sign-in was cancelled.", null); loginResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
