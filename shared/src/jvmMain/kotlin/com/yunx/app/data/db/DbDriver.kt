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
import app.cash.sqldelight.TransacterImpl
import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import java.io.File
actual fun createDbDriver(): SqlDriver {
    val directory = File(System.getProperty("user.home"), ".yunx-ios").apply { mkdirs() }
    val driver = JdbcSqliteDriver("jdbc:sqlite:${File(directory, "yunx.db").absolutePath}")
    try {
        // SQLDelight pins one JDBC connection for the whole schema transaction.
        object : TransacterImpl(driver) {}.transaction {
            val version = driver.executeQuery(null, "PRAGMA user_version", { cursor ->
                app.cash.sqldelight.db.QueryResult.Value(if (cursor.next().value) cursor.getLong(0) ?: 0L else 0L)
            }, 0).value
            check(version <= DbSchema.version) { "Database is newer than this application" }
            if (version == 0L) DbSchema.create(driver) else if (version < DbSchema.version) DbSchema.migrate(driver, version, DbSchema.version)
            driver.execute(null, "PRAGMA user_version = ${DbSchema.version}", 0)
        }
    } catch (error: Throwable) { driver.close(); throw error }
    return driver
}
