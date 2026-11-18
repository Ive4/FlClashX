package com.follow.clash

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import java.io.File

class AppUpdateFileProvider : FileProvider()

internal class AppUpdateException(val code: String) : Exception()

@Suppress("DEPRECATION")
internal object AndroidAppUpdate {
    private const val PACKAGE_NAME = "com.follow.clash"
    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"

    private fun authority(context: Context) = "${context.packageName}.app-updates"

    fun isSupported(context: Context): Boolean =
        context.packageName == PACKAGE_NAME &&
            context.packageManager.resolveContentProvider(authority(context), 0)?.packageName == PACKAGE_NAME

    fun installerIntent(context: Context, path: String, version: String, versionCode: Long): Intent {
        if (!isSupported(context)) throw AppUpdateException("UPDATE_UNSUPPORTED")
        val apk = File(path).canonicalFile
        val directory = File(context.cacheDir, "app-updates").canonicalFile
        if (apk.name != "FlClashX-update.apk" || apk.parentFile?.parentFile != directory ||
            !apk.isFile
        ) {
            throw AppUpdateException("UPDATE_INVALID_APK")
        }

        val manager = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val installed = manager.getPackageInfo(context.packageName, flags)
        val candidate = manager.getPackageArchiveInfo(apk.path, flags)
        if (candidate == null || candidate.packageName != installed.packageName ||
            candidate.versionName != version || PackageInfoCompat.getLongVersionCode(candidate) != versionCode ||
            versionCode <= PackageInfoCompat.getLongVersionCode(installed)
        ) {
            throw AppUpdateException("UPDATE_INVALID_APK")
        }
        val installedSigners = installed.currentSigners()
        if (installedSigners.isNullOrEmpty() || installedSigners != candidate.currentSigners()) {
            throw AppUpdateException("UPDATE_SIGNER_MISMATCH")
        }

        val uri = FileProvider.getUriForFile(context, authority(context), apk)
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE)
            .setDataAndType(uri, APK_MIME_TYPE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .putExtra(Intent.EXTRA_RETURN_RESULT, true)
        val installer = manager.queryIntentActivities(
            intent,
            PackageManager.MATCH_DEFAULT_ONLY or PackageManager.MATCH_SYSTEM_ONLY,
        ).firstOrNull()?.activityInfo ?: throw AppUpdateException("UPDATE_UNSUPPORTED")
        return intent.setClassName(installer.packageName, installer.name)
    }

    private fun PackageInfo.currentSigners() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            signingInfo?.apkContentsSigners?.toSet()
        } else {
            signatures?.toSet()
        }
}
