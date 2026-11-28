package build.agora.astation_mobile

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.atem_client_ffi.*

/** Runs immutable published vectors through the packaged Android JNI library, without account keys. */
@RunWith(AndroidJUnit4::class)
class MobileDelegatedProtocolTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().context

    @Before fun loadNativeLibrary() = uniffiEnsureInitialized()

    private fun fixture(name: String): JSONObject = context.assets.open("delegated/$name.json")
        .bufferedReader().use { JSONObject(it.readText()) }
    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
    private fun JSONArray.strings() = (0 until length()).map { getString(it) }
    private fun JSONObject.number(name: String) = getLong(name).toULong()
    private fun jsonEqual(expected: Any, actual: Any) =
        assertEquals(canonicalJson(expected.toString()), canonicalJson(actual.toString()))

    private inline fun vector(name: String, block: () -> Unit) {
        try { block() } catch (error: Throwable) { throw AssertionError(name, error) }
    }

    private fun AtemException.code(): String = when (this) {
        is AtemException.Invalid -> code
        is AtemException.Membership -> code
        is AtemException.Channel -> code
        is AtemException.Refused -> code
        is AtemException.Restore -> code
        is AtemException.Publish -> code
        is AtemException.Push -> code
        is AtemException.Stored -> code
        is AtemException.Report -> code
        is AtemException.BadWelcome -> "bad_welcome"
        is AtemException.Request -> "request"
        is AtemException.State -> "state"
    }

    private fun refuses(code: String, block: () -> Unit) {
        assertEquals(code, assertThrows(AtemException::class.java, block).code())
    }

    private fun wire(item: JSONObject): String {
        if (item.has("wire")) return item.getString("wire")
        val fill = item.getJSONObject("wire_fill")
        return fill.getString("prefix") + fill.getString("fill").repeat(fill.getInt("count")) + fill.getString("suffix")
    }

    @Test fun publishedMembershipRequirementsUseTheActualClassifier() {
        val cases = fixture("r9-vectors-required-verifier").getJSONArray("cases").objects()
        assertEquals(56, cases.size)
        for (item in cases) vector(item.getString("label")) {
            val body = item.getString("body_json")
            if (item.optBoolean("reject")) {
                val error = assertThrows(AtemException.Membership::class.java) { membershipRequiredVersion(body) }
                assertEquals("membership_invalid", error.code)
                assertEquals(item.getString("reason"), error.detail)
            } else {
                val actual = membershipRequiredVersion(body)
                if (item.isNull("requirement")) assertNull(actual)
                else {
                    val expected = item.getJSONObject("requirement")
                    assertEquals(expected.getString("action"), actual?.action)
                    assertEquals(expected.getInt("minimum_version").toUInt(), actual?.minimumVersion)
                }
            }
        }
    }

    @Test fun publishedVerifierChallengesAreStrictAndBounded() {
        val cases = fixture("r9-vectors-verifier-report").getJSONArray("challenges").objects()
        assertEquals(38, cases.size)
        for (item in cases) vector(item.getString("label")) {
            val text = item.getString("text")
            if (!item.has("fields")) refuses(item.getString("code")) { parseVerifierReportChallenge(text) }
            else {
                val expected = item.getJSONObject("fields")
                val actual = parseVerifierReportChallenge(text)
                assertEquals(expected.getString("signer"), actual.signer)
                assertEquals(expected.getString("slot"), actual.slot)
                assertEquals(expected.getString("origin"), actual.origin)
                assertEquals(expected.getString("nonce"), actual.nonce)
                assertEquals(expected.number("connection"), actual.connection)
                assertEquals(expected.number("issued_at"), actual.issuedAt)
                assertEquals(expected.number("expires_at"), actual.expiresAt)
            }
        }
    }

    @Test fun publishedCallsRoundTripThroughActualAndroidReadersAndBuilders() {
        val calls = fixture("r9-vectors-station-calls").getJSONArray("calls").objects()
        assertEquals(27, calls.size)
        for (item in calls) vector(item.getString("name")) {
            val text = wire(item)
            val rebuilt = if (item.getString("direction") == "to_station") {
                refuses("wrong_message") { relayDecodeToHost(text) }
                when (val call = relayDecodeToStation(text)) {
                    is RelayToStation.ControlSync -> relayControlSync(call.requestId, call.origin, call.feedId, call.after)
                    is RelayToStation.MembershipFetch -> relayMembershipFetch(call.after)
                    is RelayToStation.ControlAck -> relayControlAck(call.ack)
                }
            } else {
                refuses("wrong_message") { relayDecodeToStation(text) }
                when (val call = relayDecodeToHost(text)) {
                    is RelayToHost.ControlSyncResult -> {
                        val judged = item.getJSONArray("judged").objects()
                        assertEquals(judged.size, call.records.size)
                        for ((record, expected) in call.records.zip(judged)) {
                            assertEquals(expected.number("feed_seq"), record.feedSeq)
                            if (expected.getBoolean("parses")) {
                                assertEquals(expected.getString("record_id"), parseControlRecord(record.recordJson).recordId)
                            } else refuses(expected.getString("error")) { parseControlRecord(record.recordJson) }
                        }
                        val build = { relayControlSyncResult(call.requestId, call.origin, call.feedId, call.after,
                            call.head, call.stationTime, call.records) }
                        val invalid = judged.firstOrNull { !it.getBoolean("parses") }
                        if (invalid != null) {
                            assertTrue(item.getBoolean("hand_assembled"))
                            refuses(invalid.getString("error")) { build() }
                            return@vector
                        }
                        build()
                    }
                    is RelayToHost.Heads -> relayHeads(call.feeds, call.membership)
                    is RelayToHost.MembershipFetchResult -> relayMembershipFetchResult(call.head, call.entries)
                    is RelayToHost.ControlSyncRefused -> relayControlSyncRefused(call.code)
                    is RelayToHost.MembershipFetchRefused -> relayMembershipFetchRefused(call.code)
                    is RelayToHost.ControlAckRefused -> relayControlAckRefused(call.code)
                }
            }
            assertEquals(text, rebuilt)
        }
    }

    @Test fun malformedCallsAreRefusedAndCompleteMessagesKeepThePublishedByteBound() {
        val vectors = fixture("r9-vectors-station-calls")
        assertEquals(262144, vectors.getInt("max_message_bytes"))
        val invalid = vectors.getJSONArray("invalid").objects()
        assertEquals(124, invalid.size)
        for (item in invalid) vector(item.getString("name")) {
            refuses(item.getString("code")) {
                if (item.getString("reader") == "to_station") relayDecodeToStation(wire(item))
                else relayDecodeToHost(wire(item))
            }
        }
        val bounds = vectors.getJSONArray("at_the_bound").objects()
        assertEquals(2, bounds.size)
        for (item in bounds) vector(item.getString("name")) {
            val text = wire(item)
            assertEquals(262144, text.toByteArray(Charsets.UTF_8).size)
            val expected = item.getJSONObject("accepts")
            when (val call = relayDecodeToHost(text)) {
                is RelayToHost.ControlSyncResult -> {
                    assertEquals(expected.number("head"), call.head)
                    assertEquals(expected.getInt("records"), call.records.size)
                    for ((index, record) in call.records.withIndex()) {
                        val parses = try { parseControlRecord(record.recordJson); true } catch (_: AtemException) { false }
                        assertEquals(expected.getJSONArray("records_parse").getBoolean(index), parses)
                    }
                }
                is RelayToHost.MembershipFetchResult -> {
                    val head = expected.getJSONObject("head")
                    assertEquals(LogHead(head.number("seq"), head.getString("hash")), call.head)
                    assertEquals(expected.getInt("entries"), call.entries.size)
                }
                else -> fail("Unexpected bound fixture")
            }
        }
        assertEquals(vectors.getJSONArray("why_codes").strings(), controlWhyCodes())
    }

    @Test fun delayedRepliesCannotAnswerFreshCallsAtTheSameCursor() {
        val verdicts = mapOf("answers" to RelaySyncVerdict.ANSWERS, "request_id" to RelaySyncVerdict.REQUEST_ID,
            "origin" to RelaySyncVerdict.ORIGIN, "feed_id" to RelaySyncVerdict.FEED_ID, "after" to RelaySyncVerdict.AFTER)
        val matching = fixture("r9-vectors-station-calls").getJSONArray("matching").objects()
        assertEquals(12, matching.size)
        for (item in matching) vector(item.getString("name")) {
            val calls = item.getJSONArray("calls").strings()
            val expected = item.getJSONArray("verdicts").strings()
            assertEquals(calls.size, expected.size)
            for ((call, verdict) in calls.zip(expected)) {
                assertTrue(verdicts.containsKey(verdict))
                assertEquals(verdicts[verdict], relayControlSyncAnswers(call, item.getString("result")))
            }
        }
    }

    @Test fun ackDeadline() = acknowledgments("deadline")
    @Test fun ackLateRevocationTime() = acknowledgments("late-start")
    @Test fun ackDurableRestartAndReplicas() = acknowledgments("durable")
    @Test fun ackPerEffectAndCrossAccountRefusal() = acknowledgments("per-effect")
    @Test fun ackPortalRefusalsAndReportingStop() = acknowledgments("portal-refusals")
    @Test fun ackReasonsAreInformationOnly() = acknowledgments("reasons")
    @Test fun ackFreshManagerResign() = acknowledgments("resign")
    @Test fun ackReplacementFeedStartsWithFreshApplicationCounts() = acknowledgments("replacement-feed")

    private fun acknowledgments(suffix: String) {
        val fixture = fixture("r9-control-ack-$suffix")
        val records = fixture("r9-vectors-host-work-control").getJSONArray("records").objects().associateBy { it.getString("label") }
        val setup = fixture.getJSONObject("setup")
        val station = setup.getJSONObject("station")
        val handles = mutableListOf<AckLedgerHandle>()
        fun own(handle: AckLedgerHandle) = handle.also { handles += it }
        var ledger = own(AckLedgerHandle(station.getString("origin"), station.getString("account_id"), station.getString("genesis_hash")))
        var committed = ledger.toJson()
        var now = setup.number("station_now_ms")
        var client = if (setup.has("report_client_id")) setup.getString("report_client_id") else null

        fun transition(on: AckLedgerHandle, step: JSONObject): AckTransition? {
            val result = when {
                step.has("control_record") -> on.record(records.getValue(step.getString("control_record")).getJSONObject("record").toString(),
                    if (step.has("revoked_at_ms")) step.number("revoked_at_ms") else null,
                    step.getJSONArray("covered_hosts").strings(), now)
                step.has("learn_revoked_at") -> {
                    fun learn() = on.learnRevokedAt(step.getString("learn_revoked_at"), step.number("revoked_at_ms"), now)
                    if (step.has("refused")) {
                        refuses(step.getString("refused")) { learn() }
                        null
                    } else learn()
                }
                step.has("control_ack") -> {
                    val link = setup.getJSONObject("links").getJSONObject(step.getString("link"))
                    val association = LinkAssociationInfo(link.getString("account_id"), link.getString("genesis_hash"),
                        link.getString("host_id"), link.number("host_trust_gen"), link.getString("connection_id"))
                    val input = step.getJSONObject("control_ack").toString()
                    if (step.has("refused")) {
                        refuses(step.getString("refused")) { on.ack(association, input, now) }
                        null
                    } else on.ack(association, input, now)
                }
                step.has("tick") -> on.tick(now)
                else -> error("Unknown ledger input: $step")
            }
            result?.next?.let(::own)
            return result
        }
        fun commit(change: AckTransition) {
            if (change.next !in handles) own(change.next)
            committed = change.next.toJson()
            ledger = change.next
        }
        fun made(change: AckTransition, step: JSONObject) {
            assertEquals(step.getJSONArray("made").strings(), change.made.map { it.reportId })
            assertTrue(change.alerts.isEmpty())
        }
        fun sendable(id: String) = assertTrue(ledger.pendingReports().any { it.reportId == id })

        fun runSteps(steps: JSONArray) {
            for ((index, step) in steps.objects().withIndex()) vector("ack-$suffix step $index") {
                val before = ledger.toJson()
                when {
                    step.has("control_record") || step.has("control_ack") || step.has("learn_revoked_at") || step.has("tick") -> {
                        val change = transition(ledger, step)
                        assertEquals("A transition must not mutate its input", before, ledger.toJson())
                        if (change != null) {
                            made(change, step)
                            if (step.opt("commit") != false) commit(change)
                        }
                    }
                    step.has("replica") -> {
                        val inner = step.getJSONObject("replica")
                        val first = requireNotNull(transition(own(AckLedgerHandle.fromJson(committed)), inner))
                        val second = requireNotNull(transition(own(AckLedgerHandle.fromJson(committed)), inner))
                        assertEquals(first.next.toJson(), second.next.toJson())
                        assertEquals(first.made, second.made)
                        made(first, inner)
                        commit(first)
                        assertTrue(requireNotNull(transition(own(AckLedgerHandle.fromJson(committed)), inner)).made.isEmpty())
                    }
                    step.has("advance_ms") -> now += step.number("advance_ms")
                    step.has("branch") -> {
                        val saved = committed
                        val savedTime = now
                        val savedClient = client
                        runSteps(step.getJSONArray("branch"))
                        committed = saved
                        ledger = own(AckLedgerHandle.fromJson(saved))
                        now = savedTime
                        client = savedClient
                    }
                    step.has("either_order") -> {
                        val inputs = step.getJSONArray("either_order").objects()
                        assertEquals(2, inputs.size)
                        fun applyOrder(steps: List<JSONObject>): Pair<String, List<String>> {
                            var state = own(AckLedgerHandle.fromJson(committed))
                            val reports = mutableListOf<String>()
                            for (input in steps) {
                                val change = requireNotNull(transition(state, input))
                                assertTrue(change.alerts.isEmpty())
                                reports.addAll(change.made.map { it.reportId })
                                state = change.next
                            }
                            return state.toJson() to reports
                        }
                        val ordered = applyOrder(inputs)
                        assertEquals(ordered, applyOrder(inputs.reversed()))
                        assertEquals(step.getJSONArray("made").strings(), ordered.second)
                        committed = ordered.first
                        ledger = own(AckLedgerHandle.fromJson(committed))
                    }
                    step.has("expect_start") -> {
                        val revocations = JSONObject(committed).getJSONObject("revocations")
                        val starts = JSONObject()
                        for (principal in revocations.keys()) {
                            starts.put(principal, revocations.getJSONObject(principal).getLong("revoked_at_ms"))
                        }
                        jsonEqual(step.getJSONObject("expect_start"), starts)
                    }
                    step.has("restart") -> {
                        ledger = own(AckLedgerHandle.fromJson(committed))
                        assertEquals(committed, ledger.toJson())
                    }
                    step.has("expect_report") -> jsonEqual(step.getJSONArray("expect_report"), JSONArray(ledger.pendingReports().map(::intent)))
                    step.has("expect_counts") -> jsonEqual(step.getJSONArray("expect_counts"), JSONObject(ledger.toJson()).getJSONArray("done"))
                    step.has("confirm") -> {
                        val id = step.getString("confirm")
                        sendable(id)
                        commit(ledger.confirm(id))
                    }
                    step.has("report_failure") -> {
                        val failure = step.getJSONObject("report_failure")
                        val id = failure.getString("report_id")
                        sendable(id)
                        val status = failure.get("status")
                        val answer = if (status is Number) reportAnswer(status.toInt().toUShort()) else ReportAnswerKind.RETRY
                        assertEquals(failure.getString("answer"), answer.name.lowercase())
                        val change = when (answer) {
                            ReportAnswerKind.REFUSE -> ledger.refuse(id)
                            ReportAnswerKind.STOP_REPORTING -> ledger.stopReporting(requireNotNull(client))
                            else -> null
                        }
                        jsonEqual(failure.optJSONArray("alerts") ?: JSONArray(), JSONArray(change?.alerts?.map(::alert) ?: emptyList<JSONObject>()))
                        if (change != null) commit(change)
                    }
                    step.has("expect_resign_alerts") -> assertEquals(step.getJSONArray("expect_resign_alerts").strings().map {
                        records.getValue(it).getJSONObject("record").getJSONObject("body").getString("record_id")
                    }.sorted(), ledger.resignAlerts())
                    step.has("expect_refused") -> assertEquals(step.getJSONArray("expect_refused").strings(), ledger.refusedReports())
                    step.has("expect_dropped") -> assertEquals(step.getJSONArray("expect_dropped").strings(), ledger.droppedReports())
                    step.has("resume_reporting") -> {
                        client = step.getString("resume_reporting")
                        val change = ledger.resumeReporting(requireNotNull(client))
                        jsonEqual(step.getJSONArray("alerts"), JSONArray(change.alerts.map(::alert)))
                        assertTrue(change.made.isEmpty())
                        commit(change)
                    }
                    step.has("expect_stopped") -> {
                        assertEquals(step.get("expect_stopped"), ledger.stoppedClientId() ?: false)
                        assertEquals(step.get("expect_stopped") != false, ledger.reportingStopped())
                    }
                    // Portal's external database assertions are covered by the joint check, not this SDK runner.
                    step.has("expect_portal") -> Unit
                    else -> error("Unknown fixture step: $step")
                }
            }
        }
        try { runSteps(fixture.getJSONArray("steps")) }
        finally { handles.asReversed().forEach { it.close() } }
    }

    private fun intent(value: ReportIntentInfo): JSONObject {
        val report = when (val item = value.report) {
            is StationReport.RevocationApplied -> JSONObject().put("kind", "revocation_applied")
                .put("integration_id", item.integrationId).put("host", item.host).put("record_id", item.recordId)
            is StationReport.Revoked -> JSONObject().put("kind", "revoked").put("integration_id", item.integrationId)
                .put("outcome", item.outcome).put("pending_hosts", JSONArray(item.pendingHosts))
        }
        return JSONObject().put("not_before", JSONArray(value.notBefore)).put("report", report).put("report_id", value.reportId)
    }

    private fun alert(value: LedgerAlertInfo): JSONObject = when (value) {
        is LedgerAlertInfo.ReportRefused -> JSONObject().put("kind", "report_refused").put("report_id", value.reportId)
        is LedgerAlertInfo.ReportingStopped -> JSONObject().put("kind", "reporting_stopped").put("client_id", value.clientId)
        is LedgerAlertInfo.ReportsDropped -> JSONObject().put("kind", "reports_dropped").put("client_id", value.clientId)
            .put("dropped", JSONArray(value.dropped))
    }
}
