package com.carriez.flutter_hbb

/**
 * HorizonDesk — pont Horizon POS (SPEC caisse Horizon §6.x2, décisions D1-D7 du 14/09).
 *
 * Sans ce pont, Horizon demandait l'accord et affichait un bandeau, mais RustDesk n'en
 * savait rien : test sur tablette, un ticket a été scellé À DISTANCE pendant une session
 * « vue seule », et « Interrompre » laissait le technicien connecté. Ici, HorizonDesk
 * OBÉIT à la session Horizon :
 *
 * - D2 — aucune connexion entrante sans autorisation en cours ; avec, elle est acceptée
 *        d'office (un seul accord : celui de la caisse).
 * - D3 — clavier/souris coupés tant que la session n'est pas en contrôle.
 * - D4 — fin d'autorisation (fin, interruption, expiration) : connexions fermées, partage
 *        arrêté, poste désenregistré du relay (D1 : injoignable hors session).
 * - D5 — autorisation À DURÉE COURTE (5 min, renouvelée à chaque pulsation d'Horizon POS) :
 *        si la caisse plante ou se ferme, HorizonDesk coupe tout seul.
 * - D6 — `status` rend l'ID, l'état du partage et de la saisie : plus de saisie manuelle.
 * - D7 — seul `fr.parsight.horizonpos`, signé par la clé Parsight, peut parler au pont.
 *
 * L'état est EN MÉMOIRE seulement : un HorizonDesk tué repart désarmé (fail-closed), la
 * pulsation suivante d'Horizon POS réarme en moins de 10 s si la session est toujours là.
 */

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import ffi.FFI
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

const val ACT_HORIZON_START_SHARING = "fr.parsight.horizondesk.START_SHARING"
const val EXT_HORIZON_START = "fr.parsight.horizondesk.EXT_START"
private const val TAG = "HorizonBridge"
private const val PREFS = "horizondesk_bridge"

object HorizonPolicy {
    const val CALLER_PACKAGE = "fr.parsight.horizonpos"

    /** SHA-256 du certificat de signature d'Horizon POS (keystore EAS, relevé sur le build
     *  production du 27/08/2026). Liste : une rotation de clé ajoute une entrée. */
    val CALLER_CERTS = setOf(
        "C2:FD:F7:24:D2:67:19:A0:A2:50:58:86:70:B9:BB:BB:6B:EA:F2:6C:44:18:8C:9F:8A:5A:3D:3E:BC:BC:EC:64",
    )

    /** Plafond de l'autorisation. Ce n'est PAS la durée de l'assistance (renouvelée à
     *  chaque pulsation) : c'est la marge avant coupure quand la caisse se tait. */
    private const val MAX_TTL_MS = 600_000L

    @Volatile
    var sessionId: Long = 0
        private set
    @Volatile
    var control: Boolean = false
        private set
    @Volatile
    var until: Long = 0
        private set

    private val journal = ArrayDeque<JSONObject>()

    fun armed(): Boolean = System.currentTimeMillis() < until
    fun controlAllowed(): Boolean = armed() && control

    fun arm(session: Long, wantControl: Boolean, ttlMs: Long) {
        val fresh = !armed() || session != sessionId
        sessionId = session
        control = wantControl
        until = System.currentTimeMillis() + ttlMs.coerceIn(10_000L, MAX_TTL_MS)
        if (fresh) note("armed", "session $session")
    }

    fun disarm(reason: String) {
        if (armed()) note("disarmed", reason)
        until = 0
        control = false
    }

    @Synchronized
    fun note(kind: String, detail: String) {
        Log.i(TAG, "$kind · $detail")
        journal.addLast(JSONObject().put("at", System.currentTimeMillis()).put("kind", kind).put("detail", detail))
        while (journal.size > 20) journal.removeFirst()
    }

    @Synchronized
    fun journalJson(): String = JSONArray(journal.toList()).toString()
}

/** Applique la politique aux connexions entrantes. Appelé par MainService (événements de
 *  connexion + tic toutes les 2 s) et par le pont juste après un changement d'autorisation. */
object HorizonEnforcer {
    private var wasArmed = false
    private var appliedKeyboard: Boolean? = null
    private var appliedFor = emptySet<Int>()

    const val REFUSED = 1
    const val AUTHORIZED = 2

    /** Connexion annoncée par le moteur. `REFUSED` : fermée, rien d'autre à faire.
     *  `AUTHORIZED` : acceptée ICI (le moteur ne la réannonce pas — c'est l'UI Flutter
     *  qui démarrait la capture après son clic) → le service doit traiter comme une
     *  connexion autorisée. Sinon : déjà autorisée, permission clavier appliquée. */
    @Synchronized
    fun onConnection(id: Int, authorized: Boolean, peerId: String): Int {
        if (!HorizonPolicy.armed()) {
            FFI.hzClose(id)
            HorizonPolicy.note("refused", "$peerId · aucune session Horizon")
            return REFUSED
        }
        applyKeyboard(force = true)        // AVANT l'accès : pas une frame de saisie de trop
        if (!authorized) {
            FFI.hzAuthorize(id)
            HorizonPolicy.note("accepted", "$peerId · session ${HorizonPolicy.sessionId}")
            applyKeyboard(force = true)
            return AUTHORIZED
        }
        return 0
    }

    @Synchronized
    fun tick(service: MainService?) {
        val armed = HorizonPolicy.armed()
        val clients = liveClients(service)
        if (!armed) {
            if (clients.isNotEmpty()) {
                clients.forEach { FFI.hzClose(it.optInt("id")) }
                HorizonPolicy.note("closed", "${clients.size} connexion(s) · autorisation terminée")
            }
            if (wasArmed && service != null) {
                // D4 + D1 : fin d'autorisation → partage arrêté et poste désenregistré.
                // Seulement moteur démarré : sinon la config n'est pas chargée et l'option
                // s'écrirait ailleurs.
                FFI.hzStopService()
                Handler(Looper.getMainLooper()).post { service.destroy() }
                HorizonPolicy.note("sharing_stopped", "fin d'autorisation")
            }
            wasArmed = false
            appliedKeyboard = null
            appliedFor = emptySet()
            return
        }
        wasArmed = true
        val ids = clients.map { it.optInt("id") }.toSet()
        if (ids != appliedFor) { appliedKeyboard = null; appliedFor = ids }
        if (ids.isNotEmpty()) applyKeyboard(force = false)
    }

    private fun applyKeyboard(force: Boolean) {
        val want = HorizonPolicy.controlAllowed()
        if (force || appliedKeyboard != want) {
            FFI.hzSwitchPermissionAll("keyboard", want)
            appliedKeyboard = want
        }
    }

    fun liveClients(service: MainService?): List<JSONObject> {
        if (service == null) return emptyList()
        val raw = try { FFI.hzClientsState() } catch (e: Throwable) { "" }
        if (raw.isBlank()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }
                // Transferts de fichiers compris : une fin d'autorisation les ferme aussi.
                .filter { !it.optBoolean("disconnected") }
        } catch (e: Exception) { emptyList() }
    }
}

/**
 * Point d'entrée du pont : `content://fr.parsight.horizondesk.bridge`, méthode `call`.
 * Méthodes : `status`, `arm` (extras `session_id`, `control`, `ttl_ms`), `disarm`
 * (extra `reason`). Tout autre appelant qu'Horizon POS signé Parsight est refusé.
 */
class HorizonBridgeProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context ?: return error("no_context")
        val refusal = callerRefusal(ctx)
        if (refusal != null) {
            HorizonPolicy.note("caller_refused", refusal)
            return error("caller_refused")
        }
        when (method) {
            "status" -> {}
            "arm" -> {
                val session = extras?.getLong("session_id") ?: 0L
                if (session <= 0L) return error("session_id_required")
                HorizonPolicy.arm(session, extras?.getBoolean("control") ?: false,
                    extras?.getLong("ttl_ms") ?: 90_000L)
                HorizonEnforcer.tick(MainService.instance)
            }
            "disarm" -> {
                HorizonPolicy.disarm(extras?.getString("reason") ?: "horizon")
                HorizonEnforcer.tick(MainService.instance)
            }
            else -> return error("unknown_method")
        }
        return status(ctx)
    }

    private fun status(ctx: Context): Bundle {
        val service = MainService.instance
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // L'ID ne se lit que moteur démarré : avant, la config n'est pas chargée et la
        // lecture pourrait en fabriquer une autre. Sinon, le dernier ID connu.
        var id = prefs.getString("last_id", "") ?: ""
        if (service != null) {
            val live = try { FFI.hzGetMyId() } catch (e: Throwable) { "" }
            if (live.isNotBlank() && live != id) {
                id = live
                prefs.edit().putString("last_id", live).apply()
            }
        }
        val connections = JSONArray(HorizonEnforcer.liveClients(service).map {
            JSONObject().put("peer_id", it.optString("peer_id"))
                .put("name", it.optString("name"))
                .put("authorized", it.optBoolean("authorized"))
                .put("keyboard", it.optBoolean("keyboard"))
                .put("file_transfer", it.optBoolean("is_file_transfer"))
        })
        return Bundle().apply {
            putBoolean("ok", true)
            putInt("bridge_version", 1)
            putString("version", try {
                ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""
            } catch (e: Exception) { "" })
            putString("id", id)
            putBoolean("service", service != null)
            putBoolean("sharing", MainService.isReady)
            putBoolean("input_enabled", InputService.isOpen)
            putBoolean("armed", HorizonPolicy.armed())
            putBoolean("control", HorizonPolicy.controlAllowed())
            putLong("session_id", if (HorizonPolicy.armed()) HorizonPolicy.sessionId else 0L)
            putString("connections", connections.toString())
            putString("journal", HorizonPolicy.journalJson())
        }
    }

    /** null si l'appelant est Horizon POS signé Parsight ; sinon la raison du refus. */
    private fun callerRefusal(ctx: Context): String? {
        val pkg = try { callingPackage } catch (e: SecurityException) { null }
            ?: return "appelant inconnu"
        if (pkg != HorizonPolicy.CALLER_PACKAGE) return "paquet $pkg"
        val pm = ctx.packageManager
        val certs: List<ByteArray> = try {
            if (Build.VERSION.SDK_INT >= 28) {
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                val si = info.signingInfo ?: return "signature illisible"
                (if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory)
                    .map { it.toByteArray() }
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures?.map { it.toByteArray() }
                    ?: emptyList()
            }
        } catch (e: Exception) { return "signature illisible" }
        val md = MessageDigest.getInstance("SHA-256")
        val prints = certs.map { c -> md.digest(c).joinToString(":") { "%02X".format(it) } }
        return if (prints.any { it in HorizonPolicy.CALLER_CERTS }) null else "signature non Parsight"
    }

    private fun error(code: String) = Bundle().apply { putBoolean("ok", false); putString("error", code) }

    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?): Int = 0
}

/** Entrée exportée du partage d'écran pour Horizon POS : relaie vers la demande de capture
 *  (activité privée) seulement si le pont est armé et que le partage ne tourne pas déjà. */
class HorizonShareActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (HorizonPolicy.armed() && !MainService.isReady) {
            startActivity(android.content.Intent(this, PermissionRequestTransparentActivity::class.java)
                .setAction(ACT_HORIZON_START_SHARING))
        } else {
            HorizonPolicy.note("share_ignored", if (MainService.isReady) "partage déjà actif" else "pont non armé")
        }
        finish()
    }
}
