package com.phonefix.audit

import android.app.Activity
import android.content.ComponentName
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import rikka.shizuku.Shizuku

class MainActivity : Activity() {

    private lateinit var output: TextView
    private lateinit var status: TextView
    private val target = "com.mobiletools.systemhelper"
    private var shell: IShellService? = null

    private val userServiceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(packageName, ShellService::class.java.name))
            .daemon(false)
            .processNameSuffix("shell")
            .debuggable(BuildConfig.DEBUG)
            .version(1)
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            shell = IShellService.Stub.asInterface(binder)
            status.text = "Shizuku: service connected"
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            shell = null
            status.text = "Shizuku: service disconnected"
        }
    }

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { _, grant ->
        if (grant == PackageManager.PERMISSION_GRANTED) {
            status.text = "Shizuku: granted"
            bindService()
        } else {
            status.text = "Shizuku: denied"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(56, 120, 56, 56)
        }

        val title = TextView(this).apply {
            text = "PhoneFix \u2014 M2"
            textSize = 22f
            setTextColor(Color.BLACK)
        }

        status = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.DKGRAY)
            setPadding(0, 16, 0, 16)
        }

        val btnPerm = Button(this).apply { text = "Connect / Request permission" }
        val btnDisable = Button(this).apply { text = "Disable SystemHelper" }
        val btnEnable = Button(this).apply { text = "Enable SystemHelper" }
        val btnScan = Button(this).apply { text = "Scan again" }

        output = TextView(this).apply {
            textSize = 13f
            setTextColor(Color.DKGRAY)
            setTextIsSelectable(true)
            setPadding(0, 24, 0, 0)
        }

        root.addView(title)
        root.addView(status)
        root.addView(btnPerm)
        root.addView(btnDisable)
        root.addView(btnEnable)
        root.addView(btnScan)
        root.addView(output)
        setContentView(ScrollView(this).apply { addView(root) })

        btnPerm.setOnClickListener {
            if (!Shizuku.pingBinder()) {
                output.text = "Shizuku is not running. Start Shizuku first."
            } else if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                bindService()
            } else {
                Shizuku.requestPermission(0)
            }
        }

        btnDisable.setOnClickListener { runCommand("pm disable-user --user 0 " + target) }
        btnEnable.setOnClickListener { runCommand("pm enable " + target) }
        btnScan.setOnClickListener { runScan() }

        refreshStatus()
        runScan()
    }

    override fun onResume() {
        super.onResume()
        Shizuku.addRequestPermissionResultListener(permissionListener)
        refreshStatus()
    }

    override fun onPause() {
        super.onPause()
        Shizuku.removeRequestPermissionResultListener(permissionListener)
    }

    private fun refreshStatus() {
        status.text = try {
            when {
                !Shizuku.pingBinder() -> "Shizuku: not running"
                Shizuku.isPreV11() -> "Shizuku: pre-v11, unsupported"
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED -> "Shizuku: granted"
                else -> "Shizuku: not granted"
            }
        } catch (t: Throwable) {
            "Shizuku: error " + t
        }
    }

    private fun bindService() {
        try {
            Shizuku.bindUserService(userServiceArgs, connection)
        } catch (t: Throwable) {
            output.text = "bind failed: " + t
        }
    }

    private fun runCommand(cmd: String) {
        val svc = shell
        if (svc == null) {
            output.text = "service not connected. Press Connect first."
            return
        }
        output.text = "running: " + cmd
        Thread {
            val result = try {
                svc.runCommand(cmd)
            } catch (t: Throwable) {
                "error: " + t
            }
            runOnUiThread { output.text = result }
        }.start()
    }

    private fun runScan() {
        Thread {
            val text = try { scan() } catch (t: Throwable) { "error: " + t.toString() }
            runOnUiThread { output.text = text }
        }.start()
    }

    private fun scan(): String {
        val pm = packageManager
        val sb = StringBuilder()

        val switchValue = Settings.Secure.getInt(contentResolver, "operator_service_improve_plan", -1)
        sb.append("operator_service_improve_plan = ").append(switchValue).append("\n\n")

        val flags = PackageManager.GET_PERMISSIONS or PackageManager.GET_SERVICES or
                PackageManager.GET_RECEIVERS or PackageManager.GET_ACTIVITIES
        val packages = pm.getInstalledPackages(flags)
        val keywords = listOf("systemhelper", "mobiletools", "dmreg", "guardprovider", "fanzha", "fraud")

        var found = 0
        for (pi in packages) {
            val name = pi.packageName
            if (keywords.none { name.contains(it, ignoreCase = true) }) continue
            found++

            sb.append("\n=== ").append(name).append(" ===\n")
            sb.append("version  : ").append(pi.versionName ?: "?").append("\n")
            val ai = pi.applicationInfo
            sb.append("enabled  : ").append(ai?.enabled).append("\n")
            val isSystem = ai != null && (ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            sb.append("system   : ").append(isSystem).append("\n")
            sb.append("uid      : ").append(ai?.uid).append("\n")

            val requested = pi.requestedPermissions ?: emptyArray()
            val granted = requested.filter { pm.checkPermission(it, name) == PackageManager.PERMISSION_GRANTED }
            sb.append("granted  : ").append(granted.size).append(" / ").append(requested.size).append("\n")
            for (p in granted.take(12)) sb.append("    ").append(p.substringAfterLast('.')).append("\n")

            var exported = 0
            pi.services?.forEach { if (it.exported) exported++ }
            pi.receivers?.forEach { if (it.exported) exported++ }
            pi.activities?.forEach { if (it.exported) exported++ }
            sb.append("exported : ").append(exported).append(" components\n")
        }

        if (found == 0) sb.append("no matching packages\n")
        return sb.toString()
    }
}
