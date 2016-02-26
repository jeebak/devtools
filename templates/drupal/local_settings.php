<?php
ini_set('memory_limit', '1024M');
# ini_set('max_execution_time', 0);

# Drupal 6
$db_url = 'mysql://__MYSQL_DB__:__MYSQL_DB__@localhost/__MYSQL_DB__';
# Drupal 7
$databases['default']['default'] = array(
  'driver'    => 'mysql',
  'database'  => '__MYSQL_DB__',
  'username'  => '__MYSQL_DB__',
  'password'  => '__MYSQL_DB__',
  'host'      => 'localhost',
  'collation' => 'utf8_general_ci',
);

// Optimize CSS files
$conf = array(
  'cache'            => FALSE,
  'preprocess_css'   => FALSE,
  'preprocess_js'    => FALSE,
  'block_cache'      => FALSE,
  'page_compression' => FALSE,
);

// Configure Environment Indicator 7.x-2.x
// Whether the Environment Indicator should use the settings.php variables for the indicator. On your production environment, you should probably set this to FALSE.
$conf['environment_indicator_overwrite'] = TRUE;

// Clearly show we're on on local dev environment.
$conf['environment_indicator_overwritten_name'] = '*** LOCAL DEV ***';

// Valid css colors for the text and background of the admin toolbar and environment indicator.
$conf['environment_indicator_overwritten_color'] = '#9f3dad';
$conf['environment_indicator_overwritten_text_color'] = '#ffffff'; // Doesn't seem to do anything

// A boolean value indicating whether the Environment Indicator should be visible at all times, fixed at the top/bottom of the screen.
$conf['environment_indicator_overwritten_fixed'] = TRUE;

// Configure Views
$conf['views_ui_show_sql_query'] = TRUE;
$conf['views_ui_show_performance_statistics'] = TRUE;

// Habitat settings
$conf['habitat'] = 'local';
