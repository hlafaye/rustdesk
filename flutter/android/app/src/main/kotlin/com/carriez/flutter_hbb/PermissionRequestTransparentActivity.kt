package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.ResultReceiver
import android.util.Log

class PermissionRequestTransparentActivity: Activity() {
    private val logTag = "permissionRequest"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(logTag, "onCreate PermissionRequestTransparentActivity: intent.action: ${intent.action}")

        when (intent.action) {
            ACT_REQUEST_MEDIA_PROJECTION, ACT_HORIZON_START_SHARING -> {
                // HorizonDesk : Horizon POS ouvre le partage juste après l'accord de la caisse.
                // Rien sans autorisation en cours ; rien à faire si le partage tourne déjà.
                if (intent.action == ACT_HORIZON_START_SHARING
                    && (!HorizonPolicy.armed() || MainService.isReady)) {
                    finish()
                    return
                }
                val mediaProjectionManager =
                    getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val intent = mediaProjectionManager.createScreenCaptureIntent()
                startActivityForResult(intent, REQ_REQUEST_MEDIA_PROJECTION)
            }
            else -> finish()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_REQUEST_MEDIA_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                launchService(data)
            } else {
                val resultReceiver =
                    intent.getParcelableExtra<ResultReceiver>(EXT_MEDIA_PROJECTION_RESULT_RECEIVER)
                if (resultReceiver != null) {
                    resultReceiver.send(RES_FAILED, null)
                } else {
                    setResult(RES_FAILED)
                }
            }
            // HorizonDesk : revenir à la caisse. Test C-02 (14/09) : après la fenêtre
            // « Tout l'écran », Horizon POS restait en arrière-plan — minuteries en pause,
            // plus de pulsation, et l'autorisation du pont expirait en pleine assistance.
            if (intent.action == ACT_HORIZON_START_SHARING) {
                packageManager.getLaunchIntentForPackage(HorizonPolicy.CALLER_PACKAGE)?.let {
                    it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    try { startActivity(it) } catch (e: Exception) { Log.w(logTag, "retour caisse", e) }
                }
            }
        }

        finish()
    }

    private fun launchService(mediaProjectionResultIntent: Intent) {
        Log.d(logTag, "Launch MainService")
        val serviceIntent = Intent(this, MainService::class.java)
        serviceIntent.action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
        serviceIntent.putExtra(EXT_MEDIA_PROJECTION_RES_INTENT, mediaProjectionResultIntent)
        // Démarrage par le pont : réenregistrer le poste auprès du relay (l'UI Flutter le
        // fait par `mainStartService`, que ce chemin ne traverse pas).
        if (intent.action == ACT_HORIZON_START_SHARING) {
            serviceIntent.putExtra(EXT_HORIZON_START, true)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

}
