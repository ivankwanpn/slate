package com.phonefix.audit

import android.os.RemoteException

class ShellService : IShellService.Stub() {

    @Throws(RemoteException::class)
    override fun runCommand(cmd: String): String {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
            val out = p.inputStream.bufferedReader().readText()
            val err = p.errorStream.bufferedReader().readText()
            val code = p.waitFor()
            "exit=" + code + "\n" + out + err
        } catch (t: Throwable) {
            "error: " + t
        }
    }
}
