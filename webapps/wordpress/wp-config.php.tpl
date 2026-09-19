<?php
/**
 * WordPress 配置文件（由 ZAP 应用商店生成）
 *
 * 数据库与站点由面板 provision 准备好后注入脚本环境生成本文件：
 * 站点根目录、库名、专用账号均由面板分配，脚本无权建库。
 * 生成时间: {{GENERATED_AT}}
 */
define( 'DB_NAME', '{{DB_NAME}}' );
define( 'DB_USER', '{{DB_USER}}' );
define( 'DB_PASSWORD', '{{DB_PASSWORD}}' );
define( 'DB_HOST', '{{DB_HOST}}' );
define( 'DB_CHARSET', '{{DB_CHARSET}}' );
define( 'DB_COLLATE', '{{DB_COLLATE}}' );

/** 认证密钥与盐值：由安装脚本随机生成，每个实例都不同 */
define( 'AUTH_KEY', '{{AUTH_KEY}}' );
define( 'SECURE_AUTH_KEY', '{{SECURE_AUTH_KEY}}' );
define( 'LOGGED_IN_KEY', '{{LOGGED_IN_KEY}}' );
define( 'NONCE_KEY', '{{NONCE_KEY}}' );
define( 'AUTH_SALT', '{{AUTH_SALT}}' );
define( 'SECURE_AUTH_SALT', '{{SECURE_AUTH_SALT}}' );
define( 'LOGGED_IN_SALT', '{{LOGGED_IN_SALT}}' );
define( 'NONCE_SALT', '{{NONCE_SALT}}' );

$table_prefix = '{{TABLE_PREFIX}}';

define( 'WP_DEBUG', false );
define( 'WP_HOME', '{{WP_HOME}}' );
define( 'WP_SITEURL', '{{WP_SITEURL}}' );

/* 好了，请不要再继续编辑。请保存本文件。 */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
