package build.agora.astation_mobile

import android.os.Bundle
import android.app.Activity
import net.openid.appauth.AuthorizationManagementActivity

/** Reject callback substitution and duplicate OAuth parameters before AppAuth sees them. */
class MobileRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val callback = intent?.data
        val raw = callback?.toString().orEmpty()
        val exact = "build.agora.astation.android:/oauth/callback"
        val valid = callback != null && raw.length <= 8192 && raw.substringBefore('?') == exact &&
            callback.fragment == null && callback.getQueryParameters("state").size == 1 &&
            callback.getQueryParameters("code").size <= 1 && callback.getQueryParameters("error").size <= 1 &&
            !(callback.getQueryParameter("code") != null && callback.getQueryParameter("error") != null)
        if (valid) startActivity(AuthorizationManagementActivity.createResponseHandlingIntent(this, callback))
        finish()
    }
}
