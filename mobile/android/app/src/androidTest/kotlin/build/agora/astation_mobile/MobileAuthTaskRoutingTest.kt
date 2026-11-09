package build.agora.astation_mobile

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import net.openid.appauth.AuthorizationManagementActivity
import net.openid.appauth.AuthorizationServiceConfiguration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Reproduces Chrome's return to the real app without an account or network access. */
@RunWith(AndroidJUnit4::class)
class MobileAuthTaskRoutingTest {
    private fun endpoints() = AuthorizationServiceConfiguration(
        Uri.parse("https://auth.example.invalid/authorize"), Uri.parse("https://auth.example.invalid/token"))

    @Test
    fun authorizationRequestIncludesOfflineConsentAndFreshProofs() {
        val config = MobileOAuthConfig(true)
        val request = config.authorizationRequest(endpoints())
        val query = request.toUri()
        assertEquals("consent", query.getQueryParameter("prompt"))
        assertEquals("openid profile offline_access astation.remote", query.getQueryParameter("scope"))
        assertEquals("https://station-dev.agora.build", query.getQueryParameter("resource"))
        assertEquals("astation-android", query.getQueryParameter("client_id"))
        assertEquals("build.agora.astation.android:/oauth/callback", query.getQueryParameter("redirect_uri"))
        assertEquals("S256", query.getQueryParameter("code_challenge_method"))
        val next = config.authorizationRequest(endpoints())
        for ((first, second) in listOf(request.state to next.state, request.nonce to next.nonce,
            request.codeVerifier to next.codeVerifier,
            query.getQueryParameter("code_challenge") to next.toUri().getQueryParameter("code_challenge"))) {
            assertTrue("Missing login proof", !first.isNullOrEmpty())
            assertNotEquals("Login proof was reused", first, second)
        }
    }

    @Test
    fun browserCallbackReturnsToThePendingAuthorizationActivity() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val application = instrumentation.targetContext.applicationContext as Application
        val created = AtomicInteger()
        val receivedCallback = AtomicReference<String?>()
        val returned = CountDownLatch(1)
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) {
                if (activity is AuthorizationManagementActivity) created.incrementAndGet()
            }
            override fun onActivityResumed(activity: Activity) {
                if (activity is AuthorizationManagementActivity && activity.intent.data != null) {
                    receivedCallback.set(activity.intent.data.toString())
                }
                if (activity is MainActivity && created.get() > 0) returned.countDown()
            }
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        application.registerActivityLifecycleCallbacks(callbacks)
        val request = MobileOAuthConfig(true).authorizationRequest(endpoints())
        val expectedCallback = request.redirectUri.buildUpon().appendQueryParameter("state", request.state)
            .appendQueryParameter("code", "synthetic-test-code").build().toString()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    val browser = Intent(instrumentation.context, TestOAuthBrowserActivity::class.java)
                        .putExtra("callback", expectedCallback)
                        .putExtra("target", activity.packageName)
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(
                        AuthorizationManagementActivity.createStartForResultIntent(activity, request, browser), 4380)
                }
                assertTrue("OAuth callback did not return to the app", returned.await(20, TimeUnit.SECONDS))
                assertEquals("Callback opened a new AppAuth activity and lost the pending request", 1, created.get())
                assertEquals("AppAuth returned without the authorization response", expectedCallback, receivedCallback.get())
            }
        } finally {
            application.unregisterActivityLifecycleCallbacks(callbacks)
        }
    }
}

class TestOAuthBrowserActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        // Chrome returns external schemes with NEW_TASK | CLEAR_TOP.
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(intent.getStringExtra("callback")))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setPackage(intent.getStringExtra("target"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        finish()
    }
}
