package build.agora.astation_mobile

import org.json.JSONObject
import uniffi.atem_client_ffi.canonicalJson

internal class MobileEnrollmentTransportFailure(val reason: String) : Exception("Device setup transport: $reason")

internal data class MobileEnrollmentMailbox(val expires: Long, val request: String?, val response: String?)

/** Account authentication is supplied by the existing native token provider. */
internal class MobileDeviceEnrollmentHTTP(
    private val station: String,
    private val send: suspend (String, String, JSONObject?) -> Pair<Int, JSONObject>,
) {
    suspend fun create(invitation: MobileEnrollmentInvitation, now: Long): MobileEnrollmentMailbox {
        validate(invitation, now)
        return mailbox(perform("PUT", invitation, JSONObject().put("expires", invitation.value().getLong("expires"))), invitation, now)
    }

    suspend fun read(invitation: MobileEnrollmentInvitation, now: Long): MobileEnrollmentMailbox {
        validate(invitation, now)
        return mailbox(perform("GET", invitation, null), invitation, now)
    }

    suspend fun submit(request: String, invitation: MobileEnrollmentInvitation, now: Long): MobileEnrollmentMailbox {
        MobileDeviceEnrollment.validateRequest(request, invitation, now)
        val mailbox = mailbox(perform("POST", invitation, JSONObject().put("stage", "request").put("message", JSONObject(request))), invitation, now)
        require(mailbox.request == canonicalJson(request))
        return mailbox
    }

    suspend fun publish(response: String, request: String, invitation: MobileEnrollmentInvitation, now: Long): MobileEnrollmentMailbox {
        MobileDeviceEnrollment.validateHandoff(response, invitation, request, now)
        val mailbox = mailbox(perform("POST", invitation, JSONObject().put("stage", "response").put("message", JSONObject(response))), invitation, now)
        require(mailbox.request == canonicalJson(request) && mailbox.response == canonicalJson(response))
        return mailbox
    }

    suspend fun cancel(invitation: MobileEnrollmentInvitation) {
        try { require(perform("DELETE", invitation, null).get("closed") == true) }
        catch (error: MobileEnrollmentTransportFailure) { if (error.reason != "closed") throw error }
    }

    private suspend fun perform(method: String, invitation: MobileEnrollmentInvitation, body: JSONObject?): JSONObject {
        val inv = invitation.value()
        require(inv.getString("station") == station)
        val (status, response) = send(method, "/api/remote/v1/logs/${inv.getString("genesis")}/device-enrollments/${inv.getString("id")}", body)
        if (status == 200) return response
        val code = response.optJSONObject("error")?.optString("code")
        throw MobileEnrollmentTransportFailure(when (status to code) {
            401 to "account_login_required" -> "account_login_required"
            403 to "insufficient_scope" -> "insufficient_scope"
            404 to "device_enrollment_not_found" -> "not_found"
            404 to "recovery_record_not_found" -> "security_record_not_found"
            409 to "device_enrollment_conflict", 409 to "device_enrollment_request_required" -> "conflict"
            410 to "device_enrollment_closed" -> "closed"
            429 to "device_enrollment_limit" -> "limit"
            else -> "unavailable"
        })
    }

    private fun mailbox(value: JSONObject, invitation: MobileEnrollmentInvitation, now: Long): MobileEnrollmentMailbox {
        val body = MobileDeviceEnrollment.read(value.toString(), setOf("expires", "request", "response"),
            nullableObjects = setOf("request", "response"))
        val inv = invitation.value()
        invitation.validate(inv.getString("issuer"), inv.getString("owner"), station, now)
        val expiry = MobileDeviceEnrollment.number(body, "expires")
        require(expiry == inv.getLong("expires"))
        val request = if (body.isNull("request")) null else canonicalJson(body.getJSONObject("request").toString()).also {
            MobileDeviceEnrollment.validateRequest(it, invitation, now)
        }
        val response = if (body.isNull("response")) null else canonicalJson(body.getJSONObject("response").toString()).also {
            require(request != null); MobileDeviceEnrollment.validateHandoff(it, invitation, request, now)
        }
        return MobileEnrollmentMailbox(expiry, request, response)
    }

    private fun validate(invitation: MobileEnrollmentInvitation, now: Long) {
        val inv = invitation.value()
        invitation.validate(inv.getString("issuer"), inv.getString("owner"), station, now)
    }
}
