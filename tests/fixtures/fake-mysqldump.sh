#!/usr/bin/env sh

cat <<'SQL'
-- MySQL dump 10.13  Distrib fixture
--
-- Table structure for table `wp_options`
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (1);
SQL
