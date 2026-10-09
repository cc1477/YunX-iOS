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
import app.cash.sqldelight.db.SqlSchema
import app.cash.sqldelight.db.QueryResult
import app.cash.sqldelight.db.AfterVersion
/** Room 1–8 were unrecoverable development schemas; 9–19 preserve accounts and tasks. */
internal object DbSchema : SqlSchema<QueryResult.Value<Unit>> by YunXDb.Schema {
    override fun migrate(driver: SqlDriver, oldVersion: Long, newVersion: Long, vararg callbacks: AfterVersion): QueryResult.Value<Unit> {
        if (oldVersion in 1L..8L) {
            listOf("quark_account", "uc_account", "xunlei_account", "baidu_account", "c139_account", "pan123_account", "pan115_account", "guangya_account", "ilanzou_account", "lanzou_account", "download_task", "bookmark").forEach {
                driver.execute(null, "DROP TABLE IF EXISTS $it", 0)
            }
            return YunXDb.Schema.create(driver)
        }
        return YunXDb.Schema.migrate(driver, oldVersion, newVersion, *callbacks)
    }
}
