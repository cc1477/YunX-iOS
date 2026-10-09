/*
 * YunX (云析) - A network drive share-link parser and high-speed downloader for Android.
 * Copyright (C) 2026 CYQawa
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package com.yunx.app.data.db
import app.cash.sqldelight.db.SqlDriver
import com.yunx.app.platform.PlatformLock
import com.yunx.app.platform.locked
import com.yunx.app.data.security.SecureStoreCredentialCipher
expect fun createDbDriver(): SqlDriver
class AppDatabase private constructor(val database: YunXDb) {
    init { com.yunx.app.data.security.CredentialStore.installRecovery() }
    private val credentialCipher = SecureStoreCredentialCipher.shared
    private val rawBaiduAccountDaoValue = SqlBaiduAccountDao(database.yunXDbQueries)
    fun rawBaiduAccountDao(): BaiduAccountDao = rawBaiduAccountDaoValue
    fun baiduAccountDao(): BaiduAccountDao = SecureAccountDaos.baidu(rawBaiduAccountDaoValue, credentialCipher)
    private val bookmarkDaoValue = SqlBookmarkDao(database.yunXDbQueries)
    fun bookmarkDao(): BookmarkDao = bookmarkDaoValue
    private val rawC139AccountDaoValue = SqlC139AccountDao(database.yunXDbQueries)
    fun rawC139AccountDao(): C139AccountDao = rawC139AccountDaoValue
    fun c139AccountDao(): C139AccountDao = SecureAccountDaos.c139(rawC139AccountDaoValue, credentialCipher)
    private val downloadTaskDaoValue = SqlDownloadTaskDao(database.yunXDbQueries)
    fun downloadTaskDao(): DownloadTaskDao = downloadTaskDaoValue
    private val rawGuangYaAccountDaoValue = SqlGuangYaAccountDao(database.yunXDbQueries)
    fun rawGuangYaAccountDao(): GuangYaAccountDao = rawGuangYaAccountDaoValue
    fun guangyaAccountDao(): GuangYaAccountDao = SecureAccountDaos.guangya(rawGuangYaAccountDaoValue, credentialCipher)
    private val rawILanzouAccountDaoValue = SqlILanzouAccountDao(database.yunXDbQueries)
    fun rawILanzouAccountDao(): ILanzouAccountDao = rawILanzouAccountDaoValue
    fun ilanzouAccountDao(): ILanzouAccountDao = SecureAccountDaos.ilanzou(rawILanzouAccountDaoValue, credentialCipher)
    private val rawLanzouAccountDaoValue = SqlLanzouAccountDao(database.yunXDbQueries)
    fun rawLanzouAccountDao(): LanzouAccountDao = rawLanzouAccountDaoValue
    fun lanzouAccountDao(): LanzouAccountDao = SecureAccountDaos.lanzou(rawLanzouAccountDaoValue, credentialCipher)
    private val rawPan115AccountDaoValue = SqlPan115AccountDao(database.yunXDbQueries)
    fun rawPan115AccountDao(): Pan115AccountDao = rawPan115AccountDaoValue
    fun pan115AccountDao(): Pan115AccountDao = SecureAccountDaos.pan115(rawPan115AccountDaoValue, credentialCipher)
    private val rawPan123AccountDaoValue = SqlPan123AccountDao(database.yunXDbQueries)
    fun rawPan123AccountDao(): Pan123AccountDao = rawPan123AccountDaoValue
    fun pan123AccountDao(): Pan123AccountDao = SecureAccountDaos.pan123(rawPan123AccountDaoValue, credentialCipher)
    private val rawQuarkAccountDaoValue = SqlQuarkAccountDao(database.yunXDbQueries)
    fun rawQuarkAccountDao(): QuarkAccountDao = rawQuarkAccountDaoValue
    fun quarkAccountDao(): QuarkAccountDao = SecureAccountDaos.quark(rawQuarkAccountDaoValue, credentialCipher)
    private val rawUcAccountDaoValue = SqlUCAccountDao(database.yunXDbQueries)
    fun rawUcAccountDao(): UCAccountDao = rawUcAccountDaoValue
    fun ucAccountDao(): UCAccountDao = SecureAccountDaos.uc(rawUcAccountDaoValue, credentialCipher)
    private val rawXunleiAccountDaoValue = SqlXunleiAccountDao(database.yunXDbQueries)
    fun rawXunleiAccountDao(): XunleiAccountDao = rawXunleiAccountDaoValue
    fun xunleiAccountDao(): XunleiAccountDao = SecureAccountDaos.xunlei(rawXunleiAccountDaoValue, credentialCipher)
    companion object {
        private val lock = PlatformLock()
        private var instance: AppDatabase? = null
        fun getInstance(): AppDatabase = locked(lock) {
            instance ?: AppDatabase(YunXDb(createDbDriver())).also { instance = it }
        }
        fun get(): AppDatabase = getInstance()
    }
}
