package com.proxynodeassistant.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionCatalogTest {
    @Test
    fun ss2022LocalDetectionAndManagementAreSeparateEntries() {
        val local = ActionCatalog.byCode("19")
        val manager = ActionCatalog.byCode("24")

        assertTrue(local.titleZh.contains("本机 IP"))
        assertTrue(local.titleZh.contains("添加"))
        assertTrue(local.descriptionZh.contains("OP:24"))
        assertTrue(manager.titleZh.contains("管理 SS2022 白名单"))
        assertTrue(manager.titleZh.contains("OP:19"))
        assertTrue(manager.descriptionZh.contains("查看"))
        assertTrue(manager.descriptionZh.contains("添加"))
        assertTrue(manager.descriptionZh.contains("删除"))
        assertTrue(manager.descriptionZh.contains("不接受 CIDR"))
        assertTrue(manager.descriptionEn.contains("freely add/remove"))
    }

    @Test
    fun actionCodesRemainUniqueAfterAddingAllowlistConsole() {
        val codes = ActionCatalog.all.map { it.code.lowercase() }
        assertEquals(codes.size, codes.toSet().size)
    }
}
