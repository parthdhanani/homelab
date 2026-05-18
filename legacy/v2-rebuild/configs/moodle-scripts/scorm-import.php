<?php
/**
 * scorm-import.php — CLI script for SCORM package import into Moodle
 *
 * Run inside Moodle container via docker exec:
 *   docker exec cryptex-moodle php /moodle-uploads/scorm-import.php \
 *     <zip_path> <course_id> [section] [title_override]
 *
 * Args:
 *   $argv[1]  Absolute path to .zip inside container (e.g. /moodle-uploads/package.zip)
 *   $argv[2]  Course ID (integer — must already exist in Moodle)
 *   $argv[3]  Course section number (optional, default 0)
 *   $argv[4]  Title override (optional — default: parsed from imsmanifest.xml or filename)
 *
 * Output: JSON to stdout — parsed by n8n workflow node
 *   {"status":"success","action":"created|updated","title":"...","course_id":5,"cmid":42,"url":"..."}
 *   {"status":"error","message":"..."}
 */

define('CLI_SCRIPT', true);

// Moodle bootstrap
require('/var/www/html/config.php');
require_once($CFG->libdir . '/filelib.php');
require_once($CFG->dirroot . '/mod/scorm/lib.php');
require_once($CFG->dirroot . '/course/lib.php');

// ── Args ──────────────────────────────────────────────────────────────────────

$zip_path  = $argv[1] ?? null;
$course_id = (int)($argv[2] ?? 0);
$section   = (int)($argv[3] ?? 0);
$title     = $argv[4] ?? null;

if (!$zip_path || !$course_id) {
    echo json_encode(['status' => 'error', 'message' => 'Usage: php scorm-import.php <zip_path> <course_id> [section] [title]']);
    exit(1);
}

if (!file_exists($zip_path)) {
    echo json_encode(['status' => 'error', 'message' => "File not found: $zip_path"]);
    exit(1);
}

// ── Verify course exists ──────────────────────────────────────────────────────

$course = $DB->get_record('course', ['id' => $course_id]);
if (!$course) {
    echo json_encode(['status' => 'error', 'message' => "Course ID $course_id not found"]);
    exit(1);
}

// ── Extract title from manifest (if not provided) ────────────────────────────

if (!$title) {
    $zip   = new ZipArchive();
    $title = basename($zip_path, '.zip'); // fallback
    if ($zip->open($zip_path) === true) {
        $manifest = $zip->getFromName('imsmanifest.xml');
        if ($manifest) {
            // Suppress XML errors (malformed manifests are common)
            libxml_use_internal_errors(true);
            $xml = simplexml_load_string($manifest);
            if ($xml) {
                $t = (string)$xml->organizations->organization->title;
                if (trim($t)) {
                    $title = trim($t);
                }
            }
        }
        $zip->close();
    }
}

// ── Upload zip to Moodle draft file area ─────────────────────────────────────

$admin    = get_admin();
$user_ctx = context_user::instance($admin->id);
$fs       = get_file_storage();
$draft_id = file_get_unused_draft_itemid();

$file_record = [
    'contextid' => $user_ctx->id,
    'component' => 'user',
    'filearea'  => 'draft',
    'itemid'    => $draft_id,
    'filepath'  => '/',
    'filename'  => basename($zip_path),
];

$fs->create_file_from_pathname($file_record, $zip_path);

// ── Create or update SCORM activity ──────────────────────────────────────────

$existing = $DB->get_record('scorm', ['course' => $course_id, 'name' => $title]);

if ($existing) {
    // Update existing activity package
    $existing->packagefile  = $draft_id;
    $existing->timemodified = time();
    scorm_update_instance($existing);

    $cmid   = get_coursemodule_from_instance('scorm', $existing->id)->id;
    $action = 'updated';

} else {
    // Create new SCORM activity
    $module_id = $DB->get_field('modules', 'id', ['name' => 'scorm']);

    $cm          = new stdClass();
    $cm->course  = $course_id;
    $cm->module  = $module_id;
    $cm->section = $section;
    $cm->visible = 1;
    $cm->added   = time();
    $cmid        = add_course_module($cm);

    $scorm                            = new stdClass();
    $scorm->name                      = $title;
    $scorm->course                    = $course_id;
    $scorm->coursemodule              = $cmid;
    $scorm->scormtype                 = 'local';
    $scorm->packagefile               = $draft_id;
    $scorm->intro                     = '';
    $scorm->introformat               = FORMAT_HTML;
    $scorm->grademethod               = GRADEHIGHEST;
    $scorm->maxgrade                  = 100;
    $scorm->maxattempt                = 0;  // unlimited
    $scorm->whatgrade                 = GRADEHIGHEST;
    $scorm->displaycoursestructure    = 0;
    $scorm->updatefreq                = SCORM_UPDATE_NEVER;
    $scorm->popup                     = 0;  // same window
    $scorm->width                     = 100;
    $scorm->height                    = 500;
    $scorm->displayattemptstatus      = SCORM_DISPLAY_ATTEMPTSTATUS_ALL;
    $scorm->completionstatusrequired  = SCORM_COMPLETION_STATUS_PASSED;
    $scorm->timecreated               = time();
    $scorm->timemodified              = time();

    $instance_id = scorm_add_instance($scorm, null);
    $DB->set_field('course_modules', 'instance', $instance_id, ['id' => $cmid]);
    course_add_cm_to_section($course, $cmid, $section);
    rebuild_course_cache($course_id, true);

    $action = 'created';
}

echo json_encode([
    'status'    => 'success',
    'action'    => $action,
    'title'     => $title,
    'course_id' => $course_id,
    'cmid'      => $cmid,
    'url'       => $CFG->wwwroot . '/course/view.php?id=' . $course_id,
]);
