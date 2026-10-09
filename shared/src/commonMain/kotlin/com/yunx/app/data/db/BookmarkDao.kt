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

import kotlinx.coroutines.flow.Flow

interface BookmarkDao {

    fun observeAll(): Flow<List<BookmarkEntity>>

    /** 已添加到主页快捷方式的收藏 */
    fun observeHomePinned(): Flow<List<BookmarkEntity>>

    /** 已出现的分类（去重），用于与预置分类合并展示 */
    fun observeCategories(): Flow<List<String>>

    suspend fun insert(bookmark: BookmarkEntity): Long

    suspend fun updateCategory(id: Long, category: String)

    /** 添加 / 移除主页快捷方式 */
    suspend fun updateHomePinned(id: Long, pinned: Boolean)

    /** 主页快捷方式色块的自定义文字（空串 = 自动取标题前几个字） */
    suspend fun updateHomeLabel(id: Long, label: String)

    suspend fun delete(id: Long)
}
