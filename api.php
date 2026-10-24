<?php

// ============================================================
// RECEISCAN API
// Backend: PHP + MariaDB / MySQL
//
// Mga action:
//   signup, login, change_password, list_users
//   list_branches, add_branch, set_branch, change_branch_password, assign_branch
//   request_branch_change, get_my_branch_request, cancel_branch_request,
//   list_branch_requests, decide_branch_request
//   add_transaction, get_receipt_image, get_transactions, delete_transaction, delete_all_transactions
//   save_attendance, get_attendance
//   add_log, get_logs
//   forgot_request, forgot_reset  (Forgot Password: code sa email)
//
// RULES NG TRANSACTIONS / LOGS / ACCOUNTS:
//   - Staff: sarili lang nilang scan ang nakikita
//   - Admin: may sariling BRANCH. Scan, logs at accounts ng
//            branch lang niya ang nakikita (hindi ang ibang branch).
//            Siya lang ang pwedeng magbura sa loob ng branch niya.
//   - Owner: lahat ng branch, lahat ng scan, logs at accounts.
//   - Reports: Owner lang (sa app).
//
// BAWAT OWNER AY MAY SARILING GRUPO (owner_id):
//   - Ang bagong Owner account ay panibago: walang koneksyon sa ibang
//     Owner. Hindi niya nakikita ang branches, accounts, scans, logs at
//     attendance ng ibang Owner (at ganoon din sila sa kanya).
//   - Ang Admin/Staff ay napapabilang sa Owner ng branch na pinili nila.
//
// RULES NG BRANCH:
//   - Walang branch sa pag-sign up ng staff.
//   - Pagkatapos gumawa ng account, pipili ang staff ng branch (walang
//     password) (action: set_branch).
//   - Password ng branch: hihingin lang kapag LILIPAT na ng branch
//     (request_branch_change), kasama pa rin ang approval ng admin.
//   - Admin ay pumipili rin ng branch (isang beses). Kapag may branch
//     na ang admin, ang Owner na lang ang pwedeng maglipat sa kanya
//     (action: assign_branch).
//   - Owner lang ang pwedeng magdagdag ng branch at magpalit
//     ng password ng branch.
//   - STAFF na gustong lumipat ng branch: magpapadala ng request
//     (request_branch_change). Ang Admin ng PUPUNTAHANG branch (o ang
//     Owner) ang mag-a-approve o magre-reject (decide_branch_request).
// ============================================================

header("Access-Control-Allow-Origin: *");
header("Access-Control-Allow-Methods: GET, POST, OPTIONS");
header("Access-Control-Allow-Headers: Content-Type");
header("Content-Type: application/json; charset=UTF-8");

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// ------------------------------------------------------------
// HELPER
// ------------------------------------------------------------
function response($success, $message = "", $extra = [])
{
    $data = ["success" => $success, "message" => $message];

    if (!empty($extra)) {
        $data = array_merge($data, $extra);
    }

    // Palitan ang maling UTF-8 (hal. sira na character sa OCR text) para hindi
    // pumalya ang buong sagot at lumabas na 0 ang records sa app.
    $json = json_encode($data, JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR);

    if ($json === false) {
        $json = json_encode([
            "success" => false,
            "message" => "Server could not encode the response: " . json_last_error_msg()
        ]);
    }

    echo $json;
    exit;
}



// ------------------------------------------------------------
// Magpadala ng email gamit ang EmailJS (REST API).
// Kailangan sa config.php: emailjs_service_id, emailjs_template_id,
// emailjs_public_key, emailjs_private_key
// Template variables: to_email, to_name, subject, message
// ------------------------------------------------------------
function sendEmailJs($config, $toEmail, $toName, $subject, $message, &$error = '')
{
    $serviceId = (string)($config['emailjs_service_id'] ?? '');
    $templateId = (string)($config['emailjs_template_id'] ?? '');
    $publicKey = (string)($config['emailjs_public_key'] ?? '');
    $privateKey = (string)($config['emailjs_private_key'] ?? '');

    $missing = [];
    if ($serviceId === '') $missing[] = 'emailjs_service_id';
    if ($templateId === '') $missing[] = 'emailjs_template_id';
    if ($publicKey === '') $missing[] = 'emailjs_public_key';
    if ($privateKey === '') $missing[] = 'emailjs_private_key';

    if ($missing) {
        $error = "config.php is missing: " . implode(', ', $missing)
               . ". Keys found in " . (isset($GLOBALS['configFile']) ? $GLOBALS['configFile'] : 'config.php')
               . ": " . implode(', ', array_keys($config));
        return false;
    }

    $payload = json_encode([
        "service_id" => $serviceId,
        "template_id" => $templateId,
        "user_id" => $publicKey,
        "accessToken" => $privateKey,
        "template_params" => [
            "to_email" => $toEmail,
            "to_name" => $toName,
            "subject" => $subject,
            "message" => $message
        ]
    ]);

    if (!function_exists('curl_init')) {
        $error = "PHP cURL is not enabled on the server.";
        return false;
    }

    $ch = curl_init('https://api.emailjs.com/api/v1.0/email/send');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => $payload,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 15,
    ]);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $curlErr = curl_error($ch);
    curl_close($ch);

    if ($code !== 200) {
        $error = "EmailJS HTTP $code" . ($curlErr !== '' ? " ($curlErr)" : '')
               . ($body ? ': ' . substr(trim((string)$body), 0, 160) : '');
        return false;
    }

    return true;
}

// Ibalik bilang JSON ang anumang PHP error (hindi HTML)
set_exception_handler(function ($e) {
    response(false, "Server error: " . $e->getMessage());
});

// Hindi mag-throw ang mysqli; sinusuri natin ang resulta mismo
mysqli_report(MYSQLI_REPORT_OFF);

// ------------------------------------------------------------
// CONFIG (nasa config.php ang DB credentials at app token)
// Dapat may db_host, db_port, db_name, db_user, db_pass,
// app_token at (optional) setup_code ang config.php.
// ------------------------------------------------------------
$configFile = __DIR__ . '/config.php';

if (!file_exists($configFile)) {
    response(false, "Missing config.php. Upload config.php next to api.php.");
}

$config = require $configFile;

// ------------------------------------------------------------
// APP TOKEN: kailangan ng bawat tawag ang tamang token
// ------------------------------------------------------------
$expectedToken = (string)($config['app_token'] ?? '');
$givenToken = (string)($_POST['app_token'] ?? '');

if ($expectedToken === '' || !hash_equals($expectedToken, $givenToken)) {
    http_response_code(401);
    response(false, "Unauthorized.");
}

// ------------------------------------------------------------
// DATABASE CONNECTION
// ------------------------------------------------------------
$host     = $config['db_host'] ?? 'localhost';
$port     = (int)($config['db_port'] ?? 3306);
$dbname   = $config['db_name'] ?? 'u192368918_scanpay';
$username = $config['db_user'] ?? 'u192368918_pawsdbms';
$password = $config['db_pass'] ?? '0909217898Jb';

if ($dbname === '' || $username === '') {
    response(false, "Missing db_name / db_user / db_pass in config.php.");
}

$conn = new mysqli($host, $username, $password, $dbname, $port);

if ($conn->connect_error) {
    response(false, "Database connection failed: " . $conn->connect_error);
}

$conn->set_charset("utf8mb4");

// ------------------------------------------------------------
// ROLE HELPERS
// Ang role ay laging kinukuha sa database gamit ang user_id,
// HINDI sa ipinadala ng app.
// ------------------------------------------------------------
function getUserRole($conn, $userId)
{
    if ($userId <= 0) {
        return '';
    }

    $stmt = $conn->prepare("SELECT role FROM users WHERE id = ? LIMIT 1");

    if (!$stmt) {
        return '';
    }

    $stmt->bind_param("i", $userId);
    $stmt->execute();
    $res = $stmt->get_result();
    $row = $res ? $res->fetch_assoc() : null;
    $stmt->close();

    return $row ? strtolower(trim((string)$row['role'])) : '';
}

function isManagerRole($role)
{
    return $role === 'owner';
}

function isOwnerRole($role)
{
    return $role === 'owner';
}

// Aling Owner ang kinabibilangan ng user? (Owner: sarili niyang id.)
// 0 kung wala pa (hal. staff na hindi pa pumipili ng branch).
function getUserOwnerId($conn, $userId)
{
    if ($userId <= 0) {
        return 0;
    }

    $stmt = $conn->prepare("SELECT id, role, owner_id FROM users WHERE id = ? LIMIT 1");

    if (!$stmt) {
        return 0;
    }

    $stmt->bind_param("i", $userId);
    $stmt->execute();
    $res = $stmt->get_result();
    $row = $res ? $res->fetch_assoc() : null;
    $stmt->close();

    if (!$row) {
        return 0;
    }

    if (strtolower(trim((string)$row['role'])) === 'owner') {
        return intval($row['id']);
    }

    return intval($row['owner_id']);
}

// Unique na code ng bawat Owner (hal. OWN-7KQ2M9). Ito ang ilalagay ng
// Staff/Admin sa paggawa ng account para mapabilang sa Owner na yun.
function generateOwnerCode($conn)
{
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    for ($try = 0; $try < 50; $try++) {
        $code = 'OWN-';

        for ($i = 0; $i < 6; $i++) {
            $code .= $chars[random_int(0, strlen($chars) - 1)];
        }

        $stmt = $conn->prepare("SELECT id FROM users WHERE owner_code = ? LIMIT 1");

        if (!$stmt) {
            return $code;
        }

        $stmt->bind_param("s", $code);
        $stmt->execute();
        $exists = $stmt->get_result()->num_rows > 0;
        $stmt->close();

        if (!$exists) {
            return $code;
        }
    }

    return 'OWN-' . strtoupper(bin2hex(random_bytes(4)));
}

function getOwnerIdByCode($conn, $code)
{
    $code = strtoupper(trim((string)$code));

    if ($code === '') {
        return 0;
    }

    $stmt = $conn->prepare("SELECT id FROM users WHERE owner_code = ? AND LOWER(role) = 'owner' LIMIT 1");

    if (!$stmt) {
        return 0;
    }

    $stmt->bind_param("s", $code);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    $stmt->close();

    return $row ? intval($row['id']) : 0;
}

// Aling Owner ang may-ari ng isang transaction (sa pamamagitan ng nag-scan)
function getTransactionOwnerId($conn, $transactionId)
{
    $stmt = $conn->prepare("
        SELECT u.id, u.role, u.owner_id
        FROM transactions t
        JOIN users u ON u.id = t.user_id
        WHERE t.id = ? LIMIT 1
    ");

    if (!$stmt) {
        return 0;
    }

    $stmt->bind_param("i", $transactionId);
    $stmt->execute();
    $res = $stmt->get_result();
    $row = $res ? $res->fetch_assoc() : null;
    $stmt->close();

    if (!$row) {
        return 0;
    }

    if (strtolower(trim((string)$row['role'])) === 'owner') {
        return intval($row['id']);
    }

    return intval($row['owner_id']);
}

// Ang pinakaunang Owner (may-ari ng mga lumang record na walang user_id)
function getFirstOwnerId($conn)
{
    $res = $conn->query("SELECT MIN(id) AS m FROM users WHERE LOWER(role) = 'owner'");
    $row = $res ? $res->fetch_assoc() : null;

    return $row ? intval($row['m']) : 0;
}

// ID ng branch ng isang user (0 kung wala)
function getUserBranchId($conn, $userId)
{
    if ($userId <= 0) {
        return 0;
    }

    $stmt = $conn->prepare("SELECT branch_id FROM users WHERE id = ? LIMIT 1");

    if (!$stmt) {
        return 0;
    }

    $stmt->bind_param("i", $userId);
    $stmt->execute();
    $res = $stmt->get_result();
    $row = $res ? $res->fetch_assoc() : null;
    $stmt->close();

    return $row ? intval($row['branch_id']) : 0;
}

// Pangalan ng branch ng isang user ('' kung wala)
function getUserBranchName($conn, $userId)
{
    $bid = getUserBranchId($conn, $userId);

    if ($bid <= 0) {
        return '';
    }

    $stmt = $conn->prepare("SELECT name FROM branches WHERE id = ? LIMIT 1");

    if (!$stmt) {
        return '';
    }

    $stmt->bind_param("i", $bid);
    $stmt->execute();
    $res = $stmt->get_result();
    $row = $res ? $res->fetch_assoc() : null;
    $stmt->close();

    return $row ? (string)$row['name'] : '';
}

// Branch ng isang transaction (ang naka-tala noong na-scan, o ang
// kasalukuyang branch ng nag-scan kung wala)
function getTransactionBranchName($conn, $transactionId)
{
    $stmt = $conn->prepare("
        SELECT COALESCE(NULLIF(t.branch_name, ''), b.name) AS branch_label
        FROM transactions t
        LEFT JOIN users u ON u.id = t.user_id
        LEFT JOIN branches b ON b.id = u.branch_id
        WHERE t.id = ? LIMIT 1
    ");

    if (!$stmt) {
        return '';
    }

    $stmt->bind_param("i", $transactionId);
    $stmt->execute();
    $res = $stmt->get_result();
    $row = $res ? $res->fetch_assoc() : null;
    $stmt->close();

    return $row ? (string)($row['branch_label'] ?? '') : '';
}

// ------------------------------------------------------------
// SCHEMA: gagawin ang mga bagong table kung wala pa
// ------------------------------------------------------------
// Mga pagtatangkang mag-save ng duplicate na reference number
$conn->query("
    CREATE TABLE IF NOT EXISTS duplicate_attempts (
        id INT AUTO_INCREMENT PRIMARY KEY,
        owner_id INT NULL,
        user_id INT NOT NULL,
        branch_name VARCHAR(190) NOT NULL DEFAULT '',
        reference_no VARCHAR(190) NOT NULL,
        customer_name VARCHAR(190) NOT NULL DEFAULT '',
        amount DECIMAL(12,2) NOT NULL DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_dup_owner (owner_id),
        INDEX idx_dup_ref (reference_no)
    )
");

// Pangalan ng nag-scan, nakasulat mismo sa duplicate_attempts
$dsn = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'duplicate_attempts' AND COLUMN_NAME = 'scanner_name'
");
if ($dsn && (int)$dsn->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE duplicate_attempts ADD COLUMN scanner_name VARCHAR(190) NOT NULL DEFAULT ''");
    $conn->query("UPDATE duplicate_attempts d JOIN users u ON u.id = d.user_id SET d.scanner_name = u.name");
}

// Request ng staff/admin na magpalit ng password (para sa Owner/Admin)
$conn->query("
    CREATE TABLE IF NOT EXISTS password_requests (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        owner_id INT NULL,
        branch_id INT NULL,
        status VARCHAR(20) NOT NULL DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_pwreq_owner (owner_id, status),
        INDEX idx_pwreq_user (user_id, status)
    )
");

$conn->query("
    CREATE TABLE IF NOT EXISTS attendance (
        id INT AUTO_INCREMENT PRIMARY KEY,
        email VARCHAR(190) NOT NULL,
        att_date DATE NOT NULL,
        status VARCHAR(20) NOT NULL DEFAULT 'Absent',
        clock_in VARCHAR(20) NOT NULL DEFAULT '',
        clock_out VARCHAR(20) NOT NULL DEFAULT '',
        late_minutes INT NOT NULL DEFAULT 0,
        overtime_minutes INT NOT NULL DEFAULT 0,
        remarks VARCHAR(255) NOT NULL DEFAULT '',
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        UNIQUE KEY uq_attendance_email_date (email, att_date)
    ) CHARACTER SET utf8mb4
");

$conn->query("
    CREATE TABLE IF NOT EXISTS activity_logs (
        id INT AUTO_INCREMENT PRIMARY KEY,
        `action` VARCHAR(60) NOT NULL,
        description TEXT,
        user_name VARCHAR(120) NOT NULL DEFAULT '',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    ) CHARACTER SET utf8mb4
");

// Mga branch (may sariling password; naka-hash)
$conn->query("
    CREATE TABLE IF NOT EXISTS branches (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(120) NOT NULL,
        password_hash VARCHAR(255) NOT NULL,
        owner_id INT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uq_branch_owner_name (owner_id, name)
    ) CHARACTER SET utf8mb4
");

// Walang awtomatikong seed na branch: ang bawat Owner ay gagawa ng
// sarili niyang mga branch.

// owner_id column sa branches (kung wala pa)
$bocol = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'branches' AND COLUMN_NAME = 'owner_id'
");
if ($bocol && (int)$bocol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE branches ADD COLUMN owner_id INT NULL");
}

// Ang pangalan ng branch ay unique kada Owner (hindi na global)
$oldIdx = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'branches' AND INDEX_NAME = 'uq_branch_name'
");
if ($oldIdx && (int)$oldIdx->fetch_assoc()['c'] > 0) {
    $conn->query("ALTER TABLE branches DROP INDEX uq_branch_name");
}
$newIdx = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'branches' AND INDEX_NAME = 'uq_branch_owner_name'
");
if ($newIdx && (int)$newIdx->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE branches ADD UNIQUE KEY uq_branch_owner_name (owner_id, name)");
}

// Mga request ng staff na lumipat ng branch (kailangan ng approval)
$conn->query("
    CREATE TABLE IF NOT EXISTS branch_requests (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        from_branch_id INT NULL,
        to_branch_id INT NOT NULL,
        status VARCHAR(20) NOT NULL DEFAULT 'pending',
        decided_by INT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        decided_at TIMESTAMP NULL DEFAULT NULL,
        KEY idx_br_user (user_id),
        KEY idx_br_to (to_branch_id, status)
    ) CHARACTER SET utf8mb4
");

// Mga code para sa Forgot Password (naka-hash; may expiry at limit ng subok)
$conn->query("
    CREATE TABLE IF NOT EXISTS password_resets (
        email VARCHAR(190) NOT NULL PRIMARY KEY,
        code_hash VARCHAR(255) NOT NULL,
        attempts INT NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL,
        expires_at DATETIME NOT NULL
    ) CHARACTER SET utf8mb4
");

// branch_id column sa users (kung wala pa)
$bcol = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'branch_id'
");
if ($bcol && (int)$bcol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE users ADD COLUMN branch_id INT NULL");
}

// owner_id sa users: kung aling Owner ang kinabibilangan ng account.
// Ang Owner ay sariling id ang owner_id niya. Isang beses lang ito
// tatakbo: ang LAHAT ng kasalukuyang account at branch ay mapupunta sa
// kasalukuyang (pinakaunang) Owner; ang mga bagong Owner ay magsisimula
// sa wala.
$uocol = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'owner_id'
");
if ($uocol && (int)$uocol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE users ADD COLUMN owner_id INT NULL");
    $conn->query("UPDATE users SET owner_id = id WHERE LOWER(role) = 'owner'");

    $fo = $conn->query("SELECT MIN(id) AS m FROM users WHERE LOWER(role) = 'owner'");
    $firstOwner = $fo ? intval($fo->fetch_assoc()['m']) : 0;

    if ($firstOwner > 0) {
        $conn->query("UPDATE users SET owner_id = $firstOwner WHERE owner_id IS NULL");
        $conn->query("UPDATE branches SET owner_id = $firstOwner WHERE owner_id IS NULL");
    }
}

// Siguraduhing ang bawat Owner ay may sariling owner_id (= sarili niyang id),
// para hiwalay ang receipts at branches niya sa ibang Owner.
$conn->query("UPDATE users SET owner_id = id WHERE LOWER(role) = 'owner' AND (owner_id IS NULL OR owner_id <> id)");

// ============================================================
// RESET TO ZERO: Tanggalin ang lahat ng naka-sign sa Owner
// - Walang matitirang transaction (0 records, ₱0.00 Total Received)
// - Walang matitirang staff account (0 staff accounts)
// - Burahin ang lahat ng duplicate attempts, activity logs, attendance, at requests
// Ang matitira lamang sa system ay ang mismong account ng Owner.
// ============================================================

// 1. Burahin ang LAHAT ng transactions
$conn->query("DELETE FROM transactions");
$conn->query("ALTER TABLE transactions AUTO_INCREMENT = 1");

// 2. Burahin ang LAHAT ng duplicate attempts
$conn->query("DELETE FROM duplicate_attempts");
$conn->query("ALTER TABLE duplicate_attempts AUTO_INCREMENT = 1");

// 3. Burahin ang LAHAT ng activity logs
$conn->query("DELETE FROM activity_logs");
$conn->query("ALTER TABLE activity_logs AUTO_INCREMENT = 1");

// 4. Burahin ang LAHAT ng attendance records
$conn->query("DELETE FROM attendance");
$conn->query("ALTER TABLE attendance AUTO_INCREMENT = 1");

// 5. Burahin ang LAHAT ng branch requests at password requests
$conn->query("DELETE FROM password_requests");
$conn->query("ALTER TABLE password_requests AUTO_INCREMENT = 1");
$conn->query("DELETE FROM branch_requests");
$conn->query("ALTER TABLE branch_requests AUTO_INCREMENT = 1");
$conn->query("DELETE FROM password_resets");

// 6. Burahin ang LAHAT ng accounts na HINDI Owner (lahat ng staff at dating admin)
// Tanging ang Owner account ang matitira
$conn->query("DELETE FROM users WHERE LOWER(COALESCE(role, '')) <> 'owner'");

$ownerCountQ = $conn->query("SELECT COUNT(*) AS c, MIN(id) AS m FROM users WHERE LOWER(role) = 'owner'");
$ownerCountRow = $ownerCountQ ? $ownerCountQ->fetch_assoc() : null;

if ($ownerCountRow && (int)$ownerCountRow['c'] === 1) {
    $soleOwner = (int)$ownerCountRow['m'];
    $conn->query("UPDATE branches SET owner_id = $soleOwner WHERE owner_id IS NULL");
    $conn->query("UPDATE users SET owner_id = $soleOwner WHERE owner_id IS NULL AND LOWER(role) <> 'owner'");
}

// Ayusin ang mga Admin/Staff na may branch pero walang (o maling) owner_id:
// ang Owner nila ay ang may-ari ng branch nila. Dahil dito nakikita ng Admin
// ang scan ng Staff sa branch niya.
$conn->query("
    UPDATE users u
    JOIN branches b ON b.id = u.branch_id
    SET u.owner_id = b.owner_id
    WHERE LOWER(u.role) <> 'owner' AND b.owner_id IS NOT NULL
      AND (u.owner_id IS NULL OR u.owner_id <> b.owner_id)
");

// owner_code: unique code ng bawat Owner
$occ = $conn->query("
    SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'owner_code'
");
if ($occ && (int)$occ->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE users ADD COLUMN owner_code VARCHAR(16) NULL");
    $conn->query("ALTER TABLE users ADD UNIQUE KEY uq_owner_code (owner_code)");
}

// PIN ng account (nasa server, kaya pareho sa lahat ng phone)
foreach ([
    'pin_hash' => "VARCHAR(255) NULL",
    'pin_fails' => "INT NOT NULL DEFAULT 0",
    'pin_locked_until' => "DATETIME NULL",
] as $pcol => $pdef) {
    $pc = $conn->query("
        SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = '$pcol'
    ");
    if ($pc && (int)$pc->fetch_assoc()['c'] === 0) {
        $conn->query("ALTER TABLE users ADD COLUMN $pcol $pdef");
    }
}

// Bigyan ng code ang mga Owner na wala pa
$noCode = $conn->query("SELECT id FROM users WHERE LOWER(role) = 'owner' AND (owner_code IS NULL OR owner_code = '')");
if ($noCode) {
    while ($nc = $noCode->fetch_assoc()) {
        $newCode = generateOwnerCode($conn);
        $cu = $conn->prepare("UPDATE users SET owner_code = ? WHERE id = ?");
        if ($cu) {
            $ncId = intval($nc['id']);
            $cu->bind_param("si", $newCode, $ncId);
            $cu->execute();
            $cu->close();
        }
    }
}

// Idagdag ang sender_number (number ng sender sa receipt) kung wala pa
$scol = $conn->query("
    SELECT COUNT(*) AS c
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'transactions'
      AND COLUMN_NAME = 'sender_number'
");
if ($scol && (int)$scol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE transactions ADD COLUMN sender_number VARCHAR(40) NULL");
}

// Idagdag ang image_path (ang na-scan na larawan ng receipt) kung wala pa
$icol = $conn->query("
    SELECT COUNT(*) AS c
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'transactions'
      AND COLUMN_NAME = 'image_path'
");
if ($icol && (int)$icol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE transactions ADD COLUMN image_path VARCHAR(255) NULL");
} else {
    // Mas mahabang path na ang gagamitin (branch/buwan/file)
    $conn->query("ALTER TABLE transactions MODIFY image_path VARCHAR(255) NULL");
}

// Idagdag ang branch_name (branch ng nag-scan noong na-scan ito) kung wala pa
$brcol = $conn->query("
    SELECT COUNT(*) AS c
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'transactions'
      AND COLUMN_NAME = 'branch_name'
");
if ($brcol && (int)$brcol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE transactions ADD COLUMN branch_name VARCHAR(100) NULL");
}

// branch_id ng scan (permanente; hindi nalilito kahit magkapareho ang pangalan
// ng branch ng ibang Owner)
$brIdCol = $conn->query("
    SELECT COUNT(*) AS c
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'transactions'
      AND COLUMN_NAME = 'branch_id'
");
if ($brIdCol && (int)$brIdCol->fetch_assoc()['c'] === 0) {
    $conn->query("ALTER TABLE transactions ADD COLUMN branch_id INT NULL");
}

// Ang lumang scan na walang branch_name: itala na ngayon ang branch ng nag-scan
// para hindi na sumunod sa kanya kapag lumipat siya ng branch.
$conn->query("
    UPDATE transactions t
    JOIN users u ON u.id = t.user_id
    JOIN branches b ON b.id = u.branch_id
    SET t.branch_name = b.name
    WHERE t.branch_name IS NULL OR TRIM(t.branch_name) = ''
");

// Itala ang branch_id ng mga scan na wala pa nito (ayon sa branch_name at Owner ng nag-scan)
$conn->query("
    UPDATE transactions t
    JOIN users u ON u.id = t.user_id
    JOIN branches b ON TRIM(b.name) = TRIM(t.branch_name) AND b.owner_id = u.owner_id
    SET t.branch_id = b.id
    WHERE t.branch_id IS NULL AND t.branch_name IS NOT NULL AND TRIM(t.branch_name) <> ''
");

// Activity logs: idagdag ang user_id, role at branch_name kung wala pa
foreach ([
    'user_id'     => 'INT NULL',
    'role'        => 'VARCHAR(20) NULL',
    'branch_name' => 'VARCHAR(100) NULL',
] as $logCol => $logDef) {
    $lc = $conn->query("
        SELECT COUNT(*) AS c
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'activity_logs'
          AND COLUMN_NAME = '$logCol'
    ");
    if ($lc && (int)$lc->fetch_assoc()['c'] === 0) {
        $conn->query("ALTER TABLE activity_logs ADD COLUMN `$logCol` $logDef");
    }
}

// Ilagay sa Activity Logs ang mga duplicate na naitala na sa Reports
// (duplicate_attempts) pero wala pa sa logs. Isang beses lang kada duplicate.
$conn->query("
    INSERT INTO activity_logs (`action`, description, user_name, user_id, role, branch_name, created_at)
    SELECT 'Duplicate Receipt',
           CONCAT(COALESCE(u.name, ''), ' tried to save a duplicate receipt (ref ', d.reference_no, ').'),
           COALESCE(u.name, ''), d.user_id, COALESCE(u.role, ''), d.branch_name, d.created_at
    FROM duplicate_attempts d
    LEFT JOIN users u ON u.id = d.user_id
    WHERE NOT EXISTS (
        SELECT 1 FROM activity_logs l
        WHERE l.`action` = 'Duplicate Receipt'
          AND l.user_id = d.user_id
          AND l.created_at = d.created_at
    )
");

// Folder ng mga larawan ng receipt (hindi mabubuksan nang diretso sa browser;
// sa app lang, sa pamamagitan ng get_receipt_image)
$receiptDir = __DIR__ . '/receipts';
if (!is_dir($receiptDir)) {
    @mkdir($receiptDir, 0755, true);
}
if (is_dir($receiptDir) && !file_exists($receiptDir . '/.htaccess')) {
    @file_put_contents(
        $receiptDir . '/.htaccess',
        "Require all denied\nDeny from all\nOptions -Indexes\n"
    );
}

// Ligtas na path ng larawan: "BRANCH/YYYY-MM/file.jpg" lang, nasa loob
// ng folder na receipts. Ibabalik ang buong path o '' kung hindi ligtas.
function receiptFullPath($receiptDir, $rel)
{
    $rel = str_replace('\\', '/', trim((string)$rel));
    if ($rel === '' || strpos($rel, '..') !== false || $rel[0] === '/') {
        return '';
    }
    if (!preg_match('#^[A-Za-z0-9._\-/]+$#', $rel)) {
        return '';
    }
    return $receiptDir . '/' . $rel;
}

// Kung ENUM ang status / receipt_type ng transactions, gawing VARCHAR
// para matanggap ang mga value ng app (hal. "confirmed", "GoTyme")
$chk = $conn->query("
    SELECT COLUMN_NAME, DATA_TYPE
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'transactions'
      AND COLUMN_NAME IN ('status', 'receipt_type')
");

if ($chk) {
    while ($c = $chk->fetch_assoc()) {
        if (strtolower($c['DATA_TYPE']) === 'enum') {
            $col = $c['COLUMN_NAME'];
            $def = $col === 'status' ? "'confirmed'" : "'GCash'";
            $conn->query(
                "ALTER TABLE transactions MODIFY `$col` VARCHAR(30) NOT NULL DEFAULT $def"
            );
        }
    }
}

// ------------------------------------------------------------
// ACTION
// ------------------------------------------------------------
$action = $_POST['action'] ?? $_GET['action'] ?? '';

if ($action === '') {
    response(false, "Invalid or missing action.", [
        "method" => $_SERVER['REQUEST_METHOD'],
        "post" => $_POST,
        "get" => $_GET
    ]);
}

if ($action === 'ping') {
    response(true, "pong", ["apiVersion" => 10]);
}


// ============================================================
// SIGN UP
// ============================================================
if ($action === 'signup') {

    $name = trim($_POST['name'] ?? '');
    $email = trim($_POST['email'] ?? '');
    $plainPassword = $_POST['password'] ?? '';
    $role = trim($_POST['role'] ?? 'staff');

    if ($name === '' || $email === '' || $plainPassword === '') {
        response(false, "Name, email, and password are required.");
    }

    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
        response(false, "Invalid email address.");
    }

    if (strlen($plainPassword) < 6) {
        response(false, "Password must be at least 6 characters.");
    }

    $branchId = null;
    $ownerForUser = null;

    // Owner at Staff lang ang pinapayagan
    if ($role !== 'owner') {
        $role = 'staff';
    }

    // STAFF: kailangang pumili ng Owner kung saan sila napapabilang
    if ($role === 'staff') {
        $reqOwner = getOwnerIdByCode($conn, $_POST['owner_code'] ?? '');

        if ($reqOwner <= 0) {
            response(false, "Invalid owner ID. Please ask your owner for the correct code.");
        }

        $ownerForUser = $reqOwner;
    }

    $check = $conn->prepare("SELECT id FROM users WHERE email = ? LIMIT 1");

    if (!$check) {
        response(false, "Failed to prepare email check.");
    }

    $check->bind_param("s", $email);
    $check->execute();
    $checkResult = $check->get_result();

    if ($checkResult->num_rows > 0) {
        $check->close();
        response(false, "An account with this email already exists.");
    }

    $check->close();

    $hashedPassword = password_hash($plainPassword, PASSWORD_DEFAULT);

    // Bagong Owner: may sarili at unique na Owner ID code
    $newOwnerCode = $role === 'owner' ? generateOwnerCode($conn) : null;

    $stmt = $conn->prepare(
        "INSERT INTO users (name, email, password, role, branch_id, owner_id, owner_code) VALUES (?, ?, ?, ?, ?, ?, ?)"
    );

    if (!$stmt) {
        response(false, "Failed to prepare signup query: " . $conn->error);
    }

    $stmt->bind_param("ssssiis", $name, $email, $hashedPassword, $role, $branchId, $ownerForUser, $newOwnerCode);

    if (!$stmt->execute()) {
        $error = $stmt->error;
        $stmt->close();
        response(false, "Failed to create account: " . $error);
    }

    $userId = $stmt->insert_id;
    $stmt->close();

    // Bagong Owner = panibagong grupo (sarili niyang id ang owner_id)
    if ($role === 'owner') {
        $oo = $conn->prepare("UPDATE users SET owner_id = id WHERE id = ?");

        if ($oo) {
            $oo->bind_param("i", $userId);
            $oo->execute();
            $oo->close();
        }
    }

    $getUser = $conn->prepare(
        "SELECT u.id, u.name, u.email, u.role, u.created_at, b.name AS branch
         FROM users u LEFT JOIN branches b ON b.id = u.branch_id
         WHERE u.id = ? LIMIT 1"
    );

    if (!$getUser) {
        response(false, "Account created but failed to load user.");
    }

    $getUser->bind_param("i", $userId);
    $getUser->execute();
    $user = $getUser->get_result()->fetch_assoc();
    $getUser->close();

    response(true, "Account created successfully.", [
        "user" => [
            "id" => (int)$user["id"],
            "name" => $user["name"],
            "email" => $user["email"],
            "role" => $user["role"],
            "branch" => $user["branch"] ?? '',
            "ownerCode" => $newOwnerCode ?? '',
            "createdAt" => $user["created_at"]
        ]
    ]);
}


// ============================================================
// LOGIN
// ============================================================
if ($action === 'login') {

    $email = trim($_POST['email'] ?? '');
    $plainPassword = $_POST['password'] ?? '';

    if ($email === '' || $plainPassword === '') {
        response(false, "Email and password are required.");
    }

    $stmt = $conn->prepare(
        "SELECT u.id, u.name, u.email, u.password, u.role, u.created_at, u.owner_code, u.pin_hash, b.name AS branch
         FROM users u LEFT JOIN branches b ON b.id = u.branch_id
         WHERE u.email = ? LIMIT 1"
    );

    if (!$stmt) {
        response(false, "v2 - Failed to prepare login query: " . $conn->error);
    }

    $stmt->bind_param("s", $email);
    $stmt->execute();
    $result = $stmt->get_result();

    if ($result->num_rows === 0) {
        $stmt->close();
        response(false, "Invalid email or password.");
    }

    $user = $result->fetch_assoc();
    $stmt->close();

    if (!password_verify($plainPassword, $user['password'])) {
        response(false, "Invalid email or password.");
    }

    if (strtolower((string)$user['role']) === 'admin') {
        response(false, "Admin accounts have been removed from the system. Only Owner and Staff are allowed.");
    }

    response(true, "Login successful.", [
        // Para malaman ng app kung updated na ang api.php sa server
        "apiVersion" => 10,
        "user" => [
            "id" => (int)$user["id"],
            "name" => $user["name"],
            "email" => $user["email"],
            "role" => $user["role"],
            "branch" => $user["branch"] ?? '',
            "ownerCode" => strtolower((string)$user["role"]) === 'owner' ? ($user["owner_code"] ?? '') : '',
            "hasPin" => !empty($user["pin_hash"]),
            "createdAt" => $user["created_at"]
        ]
    ]);
}


// ============================================================
// PIN (isa lang kada account, nasa server, hindi na mapapalitan)
// ============================================================
if ($action === 'set_pin' || $action === 'verify_pin') {

    $email = trim($_POST['email'] ?? '');
    $plainPassword = $_POST['password'] ?? '';
    $pin = (string)($_POST['pin'] ?? '');

    if ($email === '' || $plainPassword === '') {
        response(false, "Email and password are required.");
    }

    $pq = $conn->prepare("SELECT id, password, pin_hash, pin_fails, pin_locked_until FROM users WHERE email = ? LIMIT 1");

    if (!$pq) {
        response(false, "Failed to prepare PIN query.");
    }

    $pq->bind_param("s", $email);
    $pq->execute();
    $pu = $pq->get_result()->fetch_assoc();
    $pq->close();

    if (!$pu || !password_verify($plainPassword, $pu['password'])) {
        response(false, "Invalid email or password.");
    }

    $pid = intval($pu['id']);

    if ($action === 'set_pin') {

        if (!empty($pu['pin_hash'])) {
            response(false, "Your PIN is already set and cannot be changed.");
        }

        if (!preg_match('/^[0-9]{4,6}$/', $pin)) {
            response(false, "PIN must be 4 to 6 digits.");
        }

        $ph = password_hash($pin, PASSWORD_DEFAULT);
        $up = $conn->prepare("UPDATE users SET pin_hash = ?, pin_fails = 0, pin_locked_until = NULL WHERE id = ? AND (pin_hash IS NULL OR pin_hash = '')");

        if (!$up) {
            response(false, "Failed to prepare PIN save.");
        }

        $up->bind_param("si", $ph, $pid);
        $up->execute();
        $changed = $up->affected_rows;
        $up->close();

        if ($changed < 1) {
            response(false, "Your PIN is already set and cannot be changed.");
        }

        response(true, "PIN created.");
    }

    // verify_pin
    if (empty($pu['pin_hash'])) {
        response(false, "No PIN has been set for this account yet.");
    }

    if (!empty($pu['pin_locked_until']) && strtotime($pu['pin_locked_until']) > time()) {
        response(false, "Too many wrong PIN attempts. Try again in a few minutes.", ["locked" => true]);
    }

    if (password_verify($pin, $pu['pin_hash'])) {
        $conn->query("UPDATE users SET pin_fails = 0, pin_locked_until = NULL WHERE id = $pid");
        response(true, "PIN verified.");
    }

    $fails = intval($pu['pin_fails']) + 1;

    if ($fails >= 5) {
        $conn->query("UPDATE users SET pin_fails = 0, pin_locked_until = DATE_ADD(NOW(), INTERVAL 5 MINUTE) WHERE id = $pid");
        response(false, "Too many wrong PIN attempts. Try again in 5 minutes.", ["locked" => true]);
    }

    $conn->query("UPDATE users SET pin_fails = $fails WHERE id = $pid");
    response(false, "Wrong PIN.");
}


// ============================================================
// LIST USERS (walang password)
// ============================================================
// Owner: lahat. Admin: mga account sa branch niya lang. Staff: sarili lang.
if ($action === 'list_users') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);

    if ($actorRole === '') {
        response(false, "User account not found.");
    }

    $where = '';

    if ($actorRole === 'owner') {
        // Owner: mga account ng sarili niyang grupo lang (hindi kasama ang admin)
        $where = "WHERE u.owner_id = " . intval(getUserOwnerId($conn, $actorId)) . " AND LOWER(u.role) <> 'admin'";
    } else {
        $where = "WHERE u.id = " . intval($actorId) . " AND LOWER(u.role) <> 'admin'";
    }

    $result = $conn->query(
        "SELECT u.id, u.name, u.email, u.role, u.created_at, b.name AS branch
         FROM users u LEFT JOIN branches b ON b.id = u.branch_id
         $where
         ORDER BY u.id ASC"
    );

    if (!$result) {
        response(false, "Failed to load users: " . $conn->error);
    }

    $users = [];

    while ($row = $result->fetch_assoc()) {
        $users[] = [
            "id" => (int)$row["id"],
            "name" => $row["name"],
            "email" => $row["email"],
            "role" => $row["role"],
            "branch" => $row["branch"] ?? '',
            "createdAt" => $row["created_at"]
        ];
    }

    response(true, "Users loaded successfully.", ["users" => $users]);
}


// ============================================================
// LIST BRANCHES (walang password)
// ============================================================
if ($action === 'list_owners') {

    // Public: para makapili ang bagong Staff/Admin kung kanino sila
    // napapabilang.
    // Hindi na ipinapakita ang listahan ng mga Owner (para sa privacy).
    // Owner ID code na ang ginagamit.
    response(false, "Owner list is no longer available. Use the Owner ID code.");
}

if ($action === 'list_branches') {

    // May user_id (naka-login): mga branch ng Owner niya lang.
    // Walang user_id (sign up): lahat, may pangalan ng Owner kung higit
    // sa isa ang Owner.
    $actorId = intval($_POST['user_id'] ?? 0);
    $ownerId = $actorId > 0 ? getUserOwnerId($conn, $actorId) : 0;

    // Sign up: pinili na ang Owner
    if ($ownerId <= 0) {
        $ownerId = getOwnerIdByCode($conn, $_POST['owner_code'] ?? '');

        if ($ownerId <= 0) {
            response(false, "Invalid Owner ID. Please check the code.");
        }
    }

    if ($ownerId > 0) {
        $stmt = $conn->prepare("
            SELECT b.id, b.name, o.name AS owner_name
            FROM branches b
            LEFT JOIN users o ON o.id = b.owner_id
            WHERE b.owner_id = ?
            ORDER BY b.name ASC
        ");

        if (!$stmt) {
            response(false, "Failed to load branches: " . $conn->error);
        }

        $stmt->bind_param("i", $ownerId);
        $stmt->execute();
        $result = $stmt->get_result();
        $stmt->close();
    } else {
        $result = $conn->query("
            SELECT b.id, b.name, b.owner_id, o.name AS owner_name
            FROM branches b
            LEFT JOIN users o ON o.id = b.owner_id
            WHERE b.owner_id IS NOT NULL
            ORDER BY o.name ASC, b.name ASC
        ");
    }

    if (!$result) {
        response(false, "Failed to load branches: " . $conn->error);
    }

    $rows = [];
    $owners = [];

    while ($row = $result->fetch_assoc()) {
        $rows[] = $row;
        $owners[(string)($row['owner_name'] ?? '')] = true;
    }

    $showOwner = $ownerId <= 0 && count($owners) > 1;
    $branches = [];

    foreach ($rows as $row) {
        $label = $row["name"];

        if ($showOwner && !empty($row['owner_name'])) {
            $label .= " (" . $row['owner_name'] . ")";
        }

        $branches[] = [
            "id" => (int)$row["id"],
            "name" => $row["name"],
            "display" => $label,
            "adminName" => ''
        ];
    }

    response(true, "Branches loaded successfully.", ["branches" => $branches]);
}


// ============================================================
// ADD BRANCH (Owner/Admin lang)
// ============================================================
if ($action === 'add_branch') {

    $actorId = intval($_POST['user_id'] ?? 0);

    if (!isOwnerRole(getUserRole($conn, $actorId))) {
        response(false, "Only the Owner can add branches.");
    }

    $bname = strtoupper(trim($_POST['name'] ?? ''));
    $bpass = (string)($_POST['password'] ?? '');

    if ($bname === '') {
        response(false, "Branch name is required.");
    }

    if (strlen($bpass) < 6) {
        response(false, "Branch password must be at least 6 characters.");
    }

    $ownerId = getUserOwnerId($conn, $actorId);

    $dup = $conn->prepare("SELECT id FROM branches WHERE name = ? AND owner_id = ? LIMIT 1");

    if (!$dup) {
        response(false, "Failed to prepare branch check.");
    }

    $dup->bind_param("si", $bname, $ownerId);
    $dup->execute();

    if ($dup->get_result()->num_rows > 0) {
        $dup->close();
        response(false, "This branch already exists.");
    }

    $dup->close();

    $hash = password_hash($bpass, PASSWORD_DEFAULT);
    $ins = $conn->prepare("INSERT INTO branches (name, password_hash, owner_id) VALUES (?, ?, ?)");

    if (!$ins) {
        response(false, "Failed to prepare branch insert: " . $conn->error);
    }

    $ins->bind_param("ssi", $bname, $hash, $ownerId);

    if (!$ins->execute()) {
        $err = $ins->error;
        $ins->close();
        response(false, "Failed to add branch: " . $err);
    }

    $ins->close();

    response(true, "Branch added successfully.");
}


// ============================================================
// SET BRANCH (staff pumipili ng branch + password ng branch)
// ============================================================
if ($action === 'set_branch') {

    $userId = intval($_POST['user_id'] ?? 0);
    $branchId = intval($_POST['branch_id'] ?? 0);
    $branchPass = (string)($_POST['branch_password'] ?? '');

    if ($userId <= 0 || $branchId <= 0) {
        response(false, "Please choose a branch.");
    }

    $targetRole = getUserRole($conn, $userId);

    if ($targetRole === '') {
        response(false, "User account not found.");
    }

    // Walang branch ang Owner (nakikita nila lahat ng branch)
    if ($targetRole === 'owner') {
        response(false, "Only staff accounts belong to a branch.");
    }

    if (getUserBranchId($conn, $userId) > 0) {
        response(false, "You already have a branch. Send a change-branch request from your Profile.");
    }

    // Kailangan ng password ng branch para hindi maghalo ang mga scan ng bawat isa
    $bs = $conn->prepare("SELECT name, password_hash, owner_id FROM branches WHERE id = ? LIMIT 1");

    if (!$bs) {
        response(false, "Failed to prepare branch check.");
    }

    $bs->bind_param("i", $branchId);
    $bs->execute();
    $brow = $bs->get_result()->fetch_assoc();
    $bs->close();

    if (!$brow) {
        response(false, "Branch not found.");
    }

    if ($branchPass === '') {
        response(false, "Branch password is required.");
    }

    if (!empty($brow['password_hash']) && !password_verify($branchPass, $brow['password_hash'])) {
        response(false, "Incorrect branch password. Please ask your Owner/Admin for the correct branch password.");
    }

    // Mapapabilang ang user sa Owner ng branch na pinili niya
    $branchOwner = $brow['owner_id'] === null ? null : intval($brow['owner_id']);

    // Hindi pwedeng pumili ng branch ng ibang Owner
    $currentOwner = getUserOwnerId($conn, $userId);

    if ($currentOwner > 0 && $branchOwner !== null && $currentOwner !== $branchOwner) {
        response(false, "That branch belongs to a different owner.");
    }

    $up = $conn->prepare("UPDATE users SET branch_id = ?, owner_id = ? WHERE id = ?");

    if (!$up) {
        response(false, "Failed to prepare branch update.");
    }

    $up->bind_param("iii", $branchId, $branchOwner, $userId);

    if (!$up->execute()) {
        $err = $up->error;
        $up->close();
        response(false, "Failed to set branch: " . $err);
    }

    $up->close();

    response(true, "Branch selected.", ["branch" => $brow['name']]);
}


// ============================================================
// CHANGE BRANCH PASSWORD (Owner/Admin lang)
// ============================================================
if ($action === 'change_branch_password') {

    $actorId = intval($_POST['user_id'] ?? 0);

    if (!isOwnerRole(getUserRole($conn, $actorId))) {
        response(false, "Only the Owner can change branch passwords.");
    }

    $branchId = intval($_POST['branch_id'] ?? 0);
    $newPass = (string)($_POST['new_password'] ?? '');

    if ($branchId <= 0) {
        response(false, "Invalid branch.");
    }

    if (strlen($newPass) < 6) {
        response(false, "Branch password must be at least 6 characters.");
    }

    $hash = password_hash($newPass, PASSWORD_DEFAULT);
    $ownerId = getUserOwnerId($conn, $actorId);
    $up = $conn->prepare("UPDATE branches SET password_hash = ? WHERE id = ? AND owner_id = ?");

    if (!$up) {
        response(false, "Failed to prepare branch update.");
    }

    $up->bind_param("sii", $hash, $branchId, $ownerId);

    if (!$up->execute()) {
        $err = $up->error;
        $up->close();
        response(false, "Failed to change branch password: " . $err);
    }

    $changed = $up->affected_rows;
    $up->close();

    if ($changed <= 0) {
        response(false, "Branch not found.");
    }

    response(true, "Branch password changed.");
}


// ============================================================
// ASSIGN BRANCH (Owner lang): ilagay / ilipat ang isang Admin o Staff
// sa isang branch (hindi na kailangan ng password ng branch).
//   branch_id = 0 -> alisin sa branch
// ============================================================
// ============================================================
// SET ADMIN BRANCH: ang Admin mismo ang pumipili / nagpapalit ng branch niya
// (hindi na pinapayagan; Owner na ang nagtatalaga ng branch ng Admin)
// ============================================================
if ($action === 'set_admin_branch') {
    response(false, "Admin role has been removed from the system.");
}

if ($action === 'assign_branch') {

    $actorId = intval($_POST['user_id'] ?? 0);

    if (!isOwnerRole(getUserRole($conn, $actorId))) {
        response(false, "Only the Owner can assign branches.");
    }

    $targetId = intval($_POST['target_id'] ?? 0);
    $branchId = intval($_POST['branch_id'] ?? 0);

    $targetRole = getUserRole($conn, $targetId);

    if ($targetRole === '') {
        response(false, "User account not found.");
    }

    if ($targetRole !== 'staff') {
        response(false, "Only staff accounts can be assigned to a branch.");
    }

    // Sarili niyang grupo lang
    $actorOwner = getUserOwnerId($conn, $actorId);

    if (getUserOwnerId($conn, $targetId) !== $actorOwner) {
        response(false, "User account not found.");
    }

    $branchName = '';

    if ($branchId > 0) {
        $bs = $conn->prepare("SELECT name FROM branches WHERE id = ? AND owner_id = ? LIMIT 1");

        if (!$bs) {
            response(false, "Failed to prepare branch check.");
        }

        $bs->bind_param("ii", $branchId, $actorOwner);
        $bs->execute();
        $brow = $bs->get_result()->fetch_assoc();
        $bs->close();

        if (!$brow) {
            response(false, "Branch not found.");
        }

        $branchName = $brow['name'];
    }

    if ($branchId > 0) {
        $up = $conn->prepare("UPDATE users SET branch_id = ? WHERE id = ?");
    } else {
        $up = $conn->prepare("UPDATE users SET branch_id = NULL WHERE id = ?");
    }

    if (!$up) {
        response(false, "Failed to prepare branch update.");
    }

    if ($branchId > 0) {
        $up->bind_param("ii", $branchId, $targetId);
    } else {
        $up->bind_param("i", $targetId);
    }

    if (!$up->execute()) {
        $err = $up->error;
        $up->close();
        response(false, "Failed to assign branch: " . $err);
    }

    $up->close();

    response(true, "Branch assigned.", ["branch" => $branchName]);
}


// ============================================================
// REQUEST BRANCH CHANGE (staff): hiling na lumipat ng branch.
// Kailangan ng approval ng Admin ng pupuntahang branch (o ng Owner).
// ============================================================
if ($action === 'request_branch_change') {

    $userId = intval($_POST['user_id'] ?? 0);
    $toId = intval($_POST['branch_id'] ?? 0);

    if (getUserRole($conn, $userId) !== 'staff') {
        response(false, "Only staff can request a branch change.");
    }

    if ($toId <= 0) {
        response(false, "Please choose a branch.");
    }

    $bs = $conn->prepare("SELECT password_hash, owner_id FROM branches WHERE id = ? LIMIT 1");

    if (!$bs) {
        response(false, "Failed to prepare branch check.");
    }

    $bs->bind_param("i", $toId);
    $bs->execute();
    $destBranch = $bs->get_result()->fetch_assoc();
    $bs->close();

    // Sa loob lang ng parehong Owner
    if (!$destBranch || intval($destBranch['owner_id']) !== getUserOwnerId($conn, $userId)) {
        response(false, "Branch not found.");
    }

    // Lilipat ng branch: kailangan ang password ng pupuntahang branch
    $givenBranchPass = (string)($_POST['branch_password'] ?? '');

    if (!password_verify($givenBranchPass, $destBranch['password_hash'])) {
        response(false, "Wrong branch password.");
    }

    $fromId = getUserBranchId($conn, $userId);

    if ($fromId === $toId) {
        response(false, "You are already in this branch.");
    }

    $pc = $conn->prepare(
        "SELECT id FROM branch_requests WHERE user_id = ? AND status = 'pending' LIMIT 1"
    );

    if (!$pc) {
        response(false, "Failed to prepare request check.");
    }

    $pc->bind_param("i", $userId);
    $pc->execute();
    $hasPending = $pc->get_result()->num_rows > 0;
    $pc->close();

    if ($hasPending) {
        response(false, "You already have a pending request. Cancel it first to send a new one.");
    }

    $ins = $conn->prepare(
        "INSERT INTO branch_requests (user_id, from_branch_id, to_branch_id, status)
         VALUES (?, NULLIF(?, 0), ?, 'pending')"
    );

    if (!$ins) {
        response(false, "Failed to prepare request: " . $conn->error);
    }

    $ins->bind_param("iii", $userId, $fromId, $toId);

    if (!$ins->execute()) {
        $err = $ins->error;
        $ins->close();
        response(false, "Failed to send request: " . $err);
    }

    $ins->close();

    response(true, "Request sent. Please wait for the owner to approve it.");
}


// ============================================================
// GET MY BRANCH REQUEST (staff): ang pinakahuling request niya
// ============================================================
if ($action === 'get_my_branch_request') {

    $userId = intval($_POST['user_id'] ?? 0);

    if (getUserRole($conn, $userId) === '') {
        response(false, "User account not found.");
    }

    $q = $conn->prepare("
        SELECT r.id, r.status, r.created_at, r.decided_at,
               fb.name AS from_branch, tb.name AS to_branch, du.name AS decided_by_name
        FROM branch_requests r
        LEFT JOIN branches fb ON fb.id = r.from_branch_id
        LEFT JOIN branches tb ON tb.id = r.to_branch_id
        LEFT JOIN users du ON du.id = r.decided_by
        WHERE r.user_id = ?
        ORDER BY r.id DESC LIMIT 1
    ");

    if (!$q) {
        response(false, "Failed to prepare request query: " . $conn->error);
    }

    $q->bind_param("i", $userId);
    $q->execute();
    $row = $q->get_result()->fetch_assoc();
    $q->close();

    if (!$row) {
        response(true, "No request.", ["request" => null]);
    }

    response(true, "OK", ["request" => [
        "id" => (int)$row["id"],
        "status" => $row["status"],
        "fromBranch" => $row["from_branch"] ?? '',
        "toBranch" => $row["to_branch"] ?? '',
        "decidedBy" => $row["decided_by_name"] ?? '',
        "createdAt" => $row["created_at"],
        "decidedAt" => $row["decided_at"] ?? ''
    ]]);
}


// ============================================================
// CANCEL BRANCH REQUEST (staff): bawiin ang sariling pending request
// ============================================================
if ($action === 'cancel_branch_request') {

    $userId = intval($_POST['user_id'] ?? 0);
    $requestId = intval($_POST['request_id'] ?? 0);

    if (getUserRole($conn, $userId) === '') {
        response(false, "User account not found.");
    }

    $up = $conn->prepare("
        UPDATE branch_requests SET status = 'cancelled', decided_at = NOW()
        WHERE id = ? AND user_id = ? AND status = 'pending'
    ");

    if (!$up) {
        response(false, "Failed to prepare cancel query.");
    }

    $up->bind_param("ii", $requestId, $userId);
    $up->execute();
    $changed = $up->affected_rows;
    $up->close();

    if ($changed <= 0) {
        response(false, "No pending request to cancel.");
    }

    response(true, "Request cancelled.");
}


// ============================================================
// LIST BRANCH REQUESTS (Owner / Admin)
//   Owner: lahat ng pending. Admin: pending papunta sa branch niya lang.
// ============================================================
if ($action === 'list_branch_requests') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can view branch requests.");
    }

    $sql = "
        SELECT r.id, r.user_id, u.name, u.email,
               fb.name AS from_branch, tb.name AS to_branch, r.created_at
        FROM branch_requests r
        JOIN users u ON u.id = r.user_id
        LEFT JOIN branches fb ON fb.id = r.from_branch_id
        JOIN branches tb ON tb.id = r.to_branch_id
        WHERE r.status = 'pending'
    ";

    // Owner at kahit sinong Admin: lahat ng request sa grupo ng Owner.
    // Sinumang isang Admin ang mag-approve/reject, tapos na ang request.
    $sql .= " AND u.owner_id = " . intval(getUserOwnerId($conn, $actorId));

    $result = $conn->query($sql . " ORDER BY r.id ASC");

    if (!$result) {
        response(false, "Failed to load requests: " . $conn->error);
    }

    $requests = [];

    while ($row = $result->fetch_assoc()) {
        $requests[] = [
            "id" => (int)$row["id"],
            "userId" => (int)$row["user_id"],
            "name" => $row["name"],
            "email" => $row["email"],
            "fromBranch" => $row["from_branch"] ?? '',
            "toBranch" => $row["to_branch"] ?? '',
            "createdAt" => $row["created_at"]
        ];
    }

    response(true, "Requests loaded successfully.", ["requests" => $requests]);
}


// ============================================================
// DECIDE BRANCH REQUEST (Owner / Admin ng pupuntahang branch)
//   decision = approve | reject
// ============================================================
if ($action === 'decide_branch_request') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);
    $requestId = intval($_POST['request_id'] ?? 0);
    $decision = strtolower(trim($_POST['decision'] ?? ''));

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can decide on requests.");
    }

    if ($decision !== 'approve' && $decision !== 'reject') {
        response(false, "Invalid decision.");
    }

    $rq = $conn->prepare(
        "SELECT user_id, to_branch_id, status FROM branch_requests WHERE id = ? LIMIT 1"
    );

    if (!$rq) {
        response(false, "Failed to prepare request query.");
    }

    $rq->bind_param("i", $requestId);
    $rq->execute();
    $req = $rq->get_result()->fetch_assoc();
    $rq->close();

    if (!$req) {
        response(false, "Request not found.");
    }

    if ($req['status'] !== 'pending') {
        response(false, "This request was already handled.");
    }

    $toId = intval($req['to_branch_id']);
    $staffId = intval($req['user_id']);

    // Owner o Admin: sa loob lang ng iisang grupo (iisang Owner).
    // Kahit sinong Admin ay pwedeng mag-approve, hindi lang ang sa pupuntahang branch.
    if (getUserOwnerId($conn, $staffId) !== getUserOwnerId($conn, $actorId)) {
        response(false, "Request not found.");
    }

    if ($decision === 'approve') {

        if (getUserRole($conn, $staffId) !== 'staff') {
            response(false, "The requester is no longer a staff account.");
        }

        $mv = $conn->prepare("UPDATE users SET branch_id = ? WHERE id = ?");

        if (!$mv) {
            response(false, "Failed to prepare branch update.");
        }

        $mv->bind_param("ii", $toId, $staffId);

        if (!$mv->execute()) {
            $err = $mv->error;
            $mv->close();
            response(false, "Failed to move the staff: " . $err);
        }

        $mv->close();
    }

    $newStatus = $decision === 'approve' ? 'approved' : 'rejected';

    $up = $conn->prepare("
        UPDATE branch_requests
        SET status = ?, decided_by = ?, decided_at = NOW()
        WHERE id = ? AND status = 'pending'
    ");

    if (!$up) {
        response(false, "Failed to prepare request update.");
    }

    $up->bind_param("sii", $newStatus, $actorId, $requestId);
    $up->execute();
    $up->close();

    response(true, $decision === 'approve' ? "Request approved." : "Request rejected.");
}


// ============================================================
// ADD TRANSACTION
// Nase-save ang user_id ng nag-scan, kaya lalabas ito sa record
// niya at sa Owner/Admin.
// ============================================================
if ($action === 'add_transaction') {

    $userId = intval($_POST['user_id'] ?? 0);
    $customerName = trim($_POST['customer_name'] ?? '');
    $dateTime = trim($_POST['date_time'] ?? '');
    $amount = $_POST['amount'] ?? '';
    $referenceNo = trim($_POST['reference_no'] ?? '');
    $status = trim($_POST['status'] ?? 'confirmed');
    $receiptType = trim($_POST['receipt_type'] ?? 'GCash');
    $rawText = $_POST['raw_text'] ?? '';
    $senderNumber = trim($_POST['sender_number'] ?? '');
    $allowDuplicate = ($_POST['allow_duplicate'] ?? '0') === '1';

    if ($userId <= 0) {
        response(false, "Invalid user ID.");
    }

    // Walang scan ang Owner (Staff lang)
    $callerRole = getUserRole($conn, $userId);
    if ($callerRole === 'owner') {
        response(false, "The Owner cannot scan receipts. Only Staff can.");
    }

    // Kailangang may branch ang nag-scan: sa branch na kinaroroonan niya
    // mapupunta ang scan, at hindi na ito lilipat kahit lumipat siya ng branch.
    if (getUserBranchId($conn, $userId) <= 0) {
        response(false, "Please choose your branch first (Profile > Change Branch) before scanning.");
    }

    if ($customerName === '') {
        response(false, "Customer name is required.");
    }

    if ($amount === '' || !is_numeric($amount)) {
        response(false, "Valid transaction amount is required.");
    }

    $amountValue = floatval($amount);

    if ($amountValue < 0) {
        response(false, "Amount cannot be negative.");
    }

    $checkUser = $conn->prepare("SELECT id FROM users WHERE id = ? LIMIT 1");

    if (!$checkUser) {
        response(false, "Failed to prepare user validation.");
    }

    $checkUser->bind_param("i", $userId);
    $checkUser->execute();

    if ($checkUser->get_result()->num_rows === 0) {
        $checkUser->close();
        response(false, "User account does not exist.");
    }

    $checkUser->close();

    // Ang "Save Anyway" (allow_duplicate) ay para sa Owner/Admin lang.
    // Staff: laging may duplicate check, kahit anong ipadala ng app.
    // Bawal na ang duplicate reference number para sa lahat (walang "Save Anyway").
    $allowDuplicate = false;

    // Duplicate reference number (maliban kung pinayagan ng Owner/Admin)
    if ($referenceNo !== '' && !$allowDuplicate) {

        // Sa loob lang ng grupo ng Owner (hindi nakikita ang iba)
        $dupOwner = getUserOwnerId($conn, $userId);

        $duplicate = $conn->prepare(
            "SELECT t.id FROM transactions t
             JOIN users u ON u.id = t.user_id
             WHERE t.reference_no = ? AND u.owner_id = ? LIMIT 1"
        );

        if ($duplicate) {
            $duplicate->bind_param("si", $referenceNo, $dupOwner);
            $duplicate->execute();

            if ($duplicate->get_result()->num_rows > 0) {
                $duplicate->close();

                // Itala ang pagtatangkang mag-duplicate para makita sa Reports
                $dupBranch = getUserBranchName($conn, $userId);
                $dupAmount = floatval($amount);
                $dupScanner = '';
                $dsq = $conn->query("SELECT name FROM users WHERE id = " . intval($userId) . " LIMIT 1");
                if ($dsq && ($dsr = $dsq->fetch_assoc())) {
                    $dupScanner = (string)$dsr['name'];
                }
                $dl = $conn->prepare(
                    "INSERT INTO duplicate_attempts (owner_id, user_id, branch_name, reference_no, customer_name, amount, scanner_name)
                     VALUES (?, ?, ?, ?, ?, ?, ?)"
                );

                if ($dl) {
                    $dl->bind_param("iisssds", $dupOwner, $userId, $dupBranch, $referenceNo, $customerName, $dupAmount, $dupScanner);
                    $dl->execute();
                    $dl->close();
                }

                // Itala din sa Activity Logs
                $lgName = '';
                $lgRole = '';
                $lq = $conn->query("SELECT name, role FROM users WHERE id = " . intval($userId) . " LIMIT 1");
                if ($lq && ($lrow = $lq->fetch_assoc())) {
                    $lgName = (string)$lrow['name'];
                    $lgRole = (string)$lrow['role'];
                }
                $lgDesc = $lgName . " tried to save a duplicate receipt (ref " . $referenceNo . ").";
                $lgAct = "Duplicate Receipt";
                $la = $conn->prepare(
                    "INSERT INTO activity_logs (`action`, description, user_name, user_id, role, branch_name)
                     VALUES (?, ?, ?, ?, ?, ?)"
                );
                if ($la) {
                    $la->bind_param("sssiss", $lgAct, $lgDesc, $lgName, $userId, $lgRole, $dupBranch);
                    $la->execute();
                    $la->close();
                }

                response(
                    false,
                    "This reference number already exists in transaction history."
                );
            }

            $duplicate->close();
        }
    }

    $stmt = $conn->prepare(
        "INSERT INTO transactions
        (user_id, customer_name, date_time, amount, reference_no, status, receipt_type, raw_text, sender_number)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    );

    if (!$stmt) {
        response(false, "Failed to prepare transaction query: " . $conn->error);
    }

    $stmt->bind_param(
        "issdsssss",
        $userId,
        $customerName,
        $dateTime,
        $amountValue,
        $referenceNo,
        $status,
        $receiptType,
        $rawText,
        $senderNumber
    );

    if (!$stmt->execute()) {
        $error = $stmt->error;
        $stmt->close();
        response(false, "Failed to save transaction: " . $error);
    }

    $transactionId = $stmt->insert_id;
    $stmt->close();

    // Itala ang branch ng nag-scan (para makita ng Owner/Admin)
    $imgBranch = 'No-Branch';
    $bq = $conn->prepare("
        SELECT b.name, b.id AS bid FROM users u
        JOIN branches b ON b.id = u.branch_id
        WHERE u.id = ? LIMIT 1
    ");
    if ($bq) {
        $bq->bind_param("i", $userId);
        $bq->execute();
        $brow = $bq->get_result()->fetch_assoc();
        $bq->close();
        if ($brow && !empty($brow['name'])) {
            $bn = $brow['name'];
            $imgBranch = trim(preg_replace('/[^A-Za-z0-9]+/', '-', $bn), '-');
            if ($imgBranch === '') $imgBranch = 'No-Branch';
            $bu = $conn->prepare("UPDATE transactions SET branch_name = ?, branch_id = ? WHERE id = ?");
            if ($bu) {
                $bidNow = intval($brow['bid']);
                $bu->bind_param("sii", $bn, $bidNow, $transactionId);
                $bu->execute();
                $bu->close();
            }
        }
    }

    // I-save ang larawan ng receipt (base64) kung may kasama
    $imageB64 = (string)($_POST['receipt_image'] ?? '');
    if ($imageB64 !== '') {
        $bin = base64_decode($imageB64, true);
        if ($bin !== false && strlen($bin) > 0 && strlen($bin) <= 8 * 1024 * 1024) {
            $info = @getimagesizefromstring($bin);
            $ext = '';
            if ($info) {
                if ($info[2] === IMAGETYPE_JPEG) $ext = 'jpg';
                elseif ($info[2] === IMAGETYPE_PNG) $ext = 'png';
            }
            if ($ext !== '' && is_dir($receiptDir)) {
                // Naka-ayos: receipts/BRANCH/YYYY-MM/ARAW_ORAS_REFERENCE_xxxx.jpg
                $ts = strtotime($dateTime);
                if ($ts === false) $ts = time();
                $subDir = $imgBranch . '/' . date('Y-m', $ts);
                $refPart = trim(preg_replace('/[^A-Za-z0-9]+/', '', $referenceNo));
                if ($refPart === '') $refPart = 'noref';
                $fileName = date('Ymd_His', $ts) . '_' . substr($refPart, 0, 24)
                    . '_' . bin2hex(random_bytes(3)) . '.' . $ext;
                $fname = $subDir . '/' . $fileName;

                if (!is_dir($receiptDir . '/' . $subDir)) {
                    @mkdir($receiptDir . '/' . $subDir, 0755, true);
                }

                if (@file_put_contents($receiptDir . '/' . $fname, $bin) !== false) {
                    $up = $conn->prepare("UPDATE transactions SET image_path = ? WHERE id = ?");
                    if ($up) {
                        $up->bind_param("si", $fname, $transactionId);
                        $up->execute();
                        $up->close();
                    }
                }
            }
        }
    }

    response(true, "Transaction saved successfully.", [
        "transaction_id" => (int)$transactionId
    ]);
}


// ============================================================
// GET TRANSACTIONS
//   Owner/Admin + scope=all  -> LAHAT ng transaction
//   Staff (o scope=mine)     -> SARILI lang nilang transaction
// ============================================================
// ============================================================
// GET DUPLICATES (Owner/Admin): ilang beses nag-duplicate ang receipt
// ============================================================
if ($action === 'get_duplicates') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can view duplicates.");
    }

    $dOwner = getUserOwnerId($conn, $actorId);
    $sql = "
        SELECT d.id, d.reference_no, d.customer_name, d.amount, d.branch_name,
               d.created_at, COALESCE(NULLIF(u.name, ''), NULLIF(d.scanner_name, ''), '') AS scanner_name
        FROM duplicate_attempts d
        LEFT JOIN users u ON u.id = d.user_id
        WHERE d.owner_id = ?
        ORDER BY d.id DESC LIMIT 1000
    ";

    $stmt = $conn->prepare($sql);

    if (!$stmt) {
        response(false, "Failed to load duplicates: " . $conn->error);
    }

    $stmt->bind_param("i", $dOwner);

    $stmt->execute();
    $res = $stmt->get_result();
    $stmt->close();

    $dups = [];

    while ($r = $res->fetch_assoc()) {
        $dups[] = [
            "id" => (int)$r['id'],
            "reference" => $r['reference_no'],
            "customer" => $r['customer_name'],
            "amount" => (float)$r['amount'],
            "branch" => $r['branch_name'],
            "scanner" => $r['scanner_name'] ?? '',
            "createdAt" => $r['created_at']
        ];
    }

    response(true, "Duplicates loaded successfully.", ["duplicates" => $dups]);
}

if ($action === 'get_transactions') {

    $userId = intval($_POST['user_id'] ?? 0);

    if ($userId <= 0) {
        response(false, "Invalid user ID.");
    }

    $role = getUserRole($conn, $userId);

    if ($role === '') {
        response(false, "User account not found.");
    }

    $wantsAll = ($_POST['scope'] ?? 'mine') === 'all';

    $baseSql = "
        SELECT t.id, t.customer_name, t.date_time, t.amount, t.reference_no,
               t.status, t.receipt_type, t.raw_text, t.sender_number, t.created_at,
               (t.image_path IS NOT NULL AND t.image_path <> '') AS has_image,
               u.name AS scanner_name,
               COALESCE(NULLIF(t.branch_name, ''), b.name) AS branch_label
        FROM transactions t
        LEFT JOIN users u ON u.id = t.user_id
        LEFT JOIN branches b ON b.id = u.branch_id
    ";

    $actorOwner = getUserOwnerId($conn, $userId);

    if (isManagerRole($role) && $wantsAll) {
        // OWNER: lahat ng scan ng staff sa sariling grupo
        $stmt = $conn->prepare($baseSql . " WHERE (u.owner_id = ? OR b.owner_id = ?) AND LOWER(COALESCE(u.role, '')) = 'staff' ORDER BY t.id DESC");

        if (!$stmt) {
            response(false, "Failed to prepare transactions query: " . $conn->error);
        }

        $stmt->bind_param("ii", $actorOwner, $actorOwner);
        $stmt->execute();
        $result = $stmt->get_result();
        $stmt->close();
    } else {
        // STAFF (o scope=mine): sarili lang, at sa kasalukuyang branch lang niya
        $myBranch = getUserBranchId($conn, $userId);

        if ($myBranch <= 0) {
            response(true, "Transactions loaded successfully.", [
                "transactions" => []
            ]);
        }

        $stmt = $conn->prepare($baseSql . " WHERE t.user_id = ? AND t.branch_id = ? ORDER BY t.id DESC");

        if (!$stmt) {
            response(false, "Failed to prepare transactions query: " . $conn->error);
        }

        $stmt->bind_param("ii", $userId, $myBranch);
        $stmt->execute();
        $result = $stmt->get_result();
        $stmt->close();
    }

    if (!$result) {
        response(false, "Failed to load transactions: " . $conn->error);
    }

    $transactions = [];

    while ($row = $result->fetch_assoc()) {

        $date = '';
        $time = '';

        if (!empty($row['date_time'])) {
            $timestamp = strtotime($row['date_time']);

            if ($timestamp !== false) {
                $date = date('Y-m-d', $timestamp);
                $time = date('H:i', $timestamp);
            } else {
                $date = $row['date_time'];
            }
        }

        $transactions[] = [
            "id" => (int)$row["id"],
            "accountName" => $row["customer_name"],
            "reference" => $row["reference_no"],
            "amount" => (float)$row["amount"],
            "date" => $date,
            "time" => $time,
            "status" => $row["status"],
            "receiptType" => $row["receipt_type"],
            "rawText" => $row["raw_text"] ?? '',
            "senderNumber" => $row["sender_number"] ?? '',
            "branch" => $row["branch_label"] ?? '',
            "hasImage" => ((int)($row["has_image"] ?? 0)) === 1,
            "scannedBy" => $row["scanner_name"] ?? '',
            "customerName" => $row["customer_name"],
            "dateTime" => $row["date_time"],
            "referenceNo" => $row["reference_no"],
            "createdAt" => $row["created_at"]
        ];
    }

    response(true, "Transactions loaded successfully.", [
        "transactions" => $transactions
    ]);
}


// ============================================================
// DELETE TRANSACTION (Owner/Admin lang)
// ============================================================
// ============================================================
// GET RECEIPT IMAGE
// Owner/Admin: kahit alin. Staff: sariling scan lang.
// ============================================================
if ($action === 'get_receipt_image') {

    $userId = intval($_POST['user_id'] ?? 0);
    $transactionId = intval($_POST['transaction_id'] ?? 0);

    $role = getUserRole($conn, $userId);
    if ($role === '') {
        response(false, "User account not found.");
    }

    $stmt = $conn->prepare("SELECT user_id, image_path FROM transactions WHERE id = ? LIMIT 1");
    if (!$stmt) {
        response(false, "Failed to prepare image query.");
    }
    $stmt->bind_param("i", $transactionId);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    $stmt->close();

    if (!$row) {
        response(false, "Transaction not found.");
    }

    if (intval($row['user_id']) !== $userId) {
        if ($role === 'owner') {
            // Owner: sa loob lang ng sarili niyang grupo
            $txOwner = getTransactionOwnerId($conn, $transactionId);

            if ($txOwner <= 0 || $txOwner !== getUserOwnerId($conn, $userId)) {
                response(false, "Transaction not found.");
            }
        } else {
            response(false, "You can only view your own scanned receipts.");
        }
    }

    $file = (string)($row['image_path'] ?? '');
    $path = receiptFullPath($receiptDir, $file);

    if ($path === '' || !is_file($path)) {
        response(false, "No receipt image was saved for this transaction.");
    }

    response(true, "OK", [
        "image" => base64_encode(file_get_contents($path)),
        "mime" => strtolower(pathinfo($file, PATHINFO_EXTENSION)) === 'png' ? 'image/png' : 'image/jpeg'
    ]);
}


if ($action === 'delete_transaction') {

    $actorId = intval($_POST['user_id'] ?? 0);

    $actorRole = getUserRole($conn, $actorId);

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can delete transactions.");
    }

    $transactionId = intval($_POST['id'] ?? 0);

    if ($transactionId <= 0) {
        response(false, "Invalid transaction ID.");
    }

    // Sa loob lang ng sarili niyang grupo
    $txOwner = getTransactionOwnerId($conn, $transactionId);

    if ($txOwner <= 0 || $txOwner !== getUserOwnerId($conn, $actorId)) {
        response(false, "Transaction not found.");
    }

    // Burahin din ang larawan ng receipt
    $imgQ = $conn->prepare("SELECT image_path FROM transactions WHERE id = ? LIMIT 1");
    if ($imgQ) {
        $imgQ->bind_param("i", $transactionId);
        $imgQ->execute();
        $imgRow = $imgQ->get_result()->fetch_assoc();
        $imgQ->close();
        if ($imgRow && !empty($imgRow['image_path'])) {
            $oldPath = receiptFullPath($receiptDir, $imgRow['image_path']);
            if ($oldPath !== '' && is_file($oldPath)) {
                @unlink($oldPath);
            }
        }
    }

    $stmt = $conn->prepare("DELETE FROM transactions WHERE id = ?");

    if (!$stmt) {
        response(false, "Failed to prepare delete query.");
    }

    $stmt->bind_param("i", $transactionId);

    if (!$stmt->execute()) {
        $error = $stmt->error;
        $stmt->close();
        response(false, "Failed to delete transaction: " . $error);
    }

    $deleted = $stmt->affected_rows;
    $stmt->close();

    if ($deleted === 0) {
        response(false, "Transaction not found.");
    }

    response(true, "Transaction deleted successfully.");
}


// ============================================================
// DELETE ALL TRANSACTIONS (Owner/Admin lang)
// ============================================================
if ($action === 'delete_all_transactions') {

    $actorId = intval($_POST['user_id'] ?? 0);

    $actorRole = getUserRole($conn, $actorId);

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can delete transactions.");
    }

    $actorOwner = getUserOwnerId($conn, $actorId);

    if ($actorOwner <= 0) {
        response(false, "You do not belong to an owner account yet.");
    }

    // OWNER: lahat ng transaction ng SARILI niyang grupo.
    $sql = "
        SELECT t.id, t.image_path
        FROM transactions t
        JOIN users u ON u.id = t.user_id
        LEFT JOIN branches b ON b.id = u.branch_id
        WHERE u.owner_id = ?
    ";

    $sel = $conn->prepare($sql);

    if (!$sel) {
        response(false, "Failed to prepare delete query.");
    }

    $sel->bind_param("i", $actorOwner);

    $sel->execute();
    $rows = $sel->get_result();
    $sel->close();

    $ids = [];

    while ($r = $rows->fetch_assoc()) {
        $ids[] = intval($r['id']);

        if (!empty($r['image_path'])) {
            $p = receiptFullPath($receiptDir, $r['image_path']);
            if ($p !== '' && is_file($p)) {
                @unlink($p);
            }
        }
    }

    if (count($ids) > 0) {
        $idList = implode(',', $ids);

        if (!$conn->query("DELETE FROM transactions WHERE id IN ($idList)")) {
            response(false, "Failed to delete transactions: " . $conn->error);
        }
    }

    response(true, "All transactions were deleted successfully.");
}


// ============================================================
// SAVE ATTENDANCE (insert o update, isa kada email kada araw)
// ============================================================
if ($action === 'save_attendance') {

    $email = trim($_POST['email'] ?? '');
    $date = trim($_POST['date'] ?? '');
    $status = trim($_POST['status'] ?? 'Absent');
    $clockIn = trim($_POST['clock_in'] ?? '');
    $clockOut = trim($_POST['clock_out'] ?? '');
    $late = intval($_POST['late_minutes'] ?? 0);
    $overtime = intval($_POST['overtime_minutes'] ?? 0);
    $remarks = trim($_POST['remarks'] ?? '');
    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);

    if ($actorRole === '') {
        response(false, "User account not found.");
    }

    if ($email === '') {
        response(false, "Email is required.");
    }

    // Sino ang may-ari ng attendance na ito?
    $tq = $conn->prepare("SELECT id, branch_id, owner_id FROM users WHERE email = ? LIMIT 1");

    if (!$tq) {
        response(false, "Failed to prepare attendance check.");
    }

    $tq->bind_param("s", $email);
    $tq->execute();
    $target = $tq->get_result()->fetch_assoc();
    $tq->close();

    if (!$target) {
        response(false, "No account found for this email.");
    }

    // Pwede: sarili (clock in/out) o Owner ng grupo
    $allowedToSave = intval($target['id']) === $actorId
        || (isOwnerRole($actorRole)
            && intval($target['owner_id']) === getUserOwnerId($conn, $actorId));

    if (!$allowedToSave) {
        response(false, "You are not authorized to edit this attendance record.");
    }

    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date)) {
        response(false, "Invalid date.");
    }

    $stmt = $conn->prepare(
        "INSERT INTO attendance
            (email, att_date, status, clock_in, clock_out, late_minutes, overtime_minutes, remarks)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE
            status = VALUES(status),
            clock_in = VALUES(clock_in),
            clock_out = VALUES(clock_out),
            late_minutes = VALUES(late_minutes),
            overtime_minutes = VALUES(overtime_minutes),
            remarks = VALUES(remarks)"
    );

    if (!$stmt) {
        response(false, "Failed to prepare attendance query: " . $conn->error);
    }

    $stmt->bind_param(
        "sssssiis",
        $email,
        $date,
        $status,
        $clockIn,
        $clockOut,
        $late,
        $overtime,
        $remarks
    );

    if (!$stmt->execute()) {
        $error = $stmt->error;
        $stmt->close();
        response(false, "Failed to save attendance: " . $error);
    }

    $stmt->close();

    response(true, "Attendance saved successfully.");
}


// ============================================================
// GET ATTENDANCE (huling 90 araw)
//   Owner: lahat. Admin: branch niya lang. Staff: sarili lang.
// ============================================================
if ($action === 'get_attendance') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);

    if ($actorRole === '') {
        response(false, "User account not found.");
    }

    $emailFilter = '';

    if ($actorRole !== '') {
        // Kunin muna ang mga email na pwedeng makita
        if ($actorRole === 'owner') {
            // Owner: mga account ng grupo ng Owner
            $eq = $conn->query(
                "SELECT email FROM users WHERE owner_id = " . intval(getUserOwnerId($conn, $actorId))
            );
        } else {
            $eq = $conn->query("SELECT email FROM users WHERE id = " . intval($actorId));
        }

        $quoted = [];

        while ($eq && ($er = $eq->fetch_assoc())) {
            $quoted[] = "'" . $conn->real_escape_string($er['email']) . "'";
        }

        if (count($quoted) === 0) {
            response(true, "Attendance loaded successfully.", ["attendance" => []]);
        }

        $emailFilter = " AND email IN (" . implode(',', $quoted) . ")";
    }

    $result = $conn->query("
        SELECT email, att_date, status, clock_in, clock_out,
               late_minutes, overtime_minutes, remarks
        FROM attendance
        WHERE att_date >= (CURDATE() - INTERVAL 90 DAY) $emailFilter
        ORDER BY att_date DESC, id DESC
    ");

    if (!$result) {
        response(false, "Failed to load attendance: " . $conn->error);
    }

    $records = [];

    while ($row = $result->fetch_assoc()) {
        $records[] = [
            "email" => $row["email"],
            "date" => $row["att_date"],
            "status" => $row["status"],
            "clockIn" => $row["clock_in"],
            "clockOut" => $row["clock_out"],
            "lateMinutes" => (int)$row["late_minutes"],
            "overtimeMinutes" => (int)$row["overtime_minutes"],
            "remarks" => $row["remarks"]
        ];
    }

    response(true, "Attendance loaded successfully.", [
        "attendance" => $records
    ]);
}


// ============================================================
// ADD LOG (activity logs)
// ============================================================
if ($action === 'add_log') {

    $logAction = trim($_POST['log_action'] ?? '');
    $description = $_POST['description'] ?? '';
    $userName = trim($_POST['user_name'] ?? '');
    $logUserId = intval($_POST['user_id'] ?? 0);
    $logRole = '';
    $logBranch = '';

    if ($logAction === '') {
        response(false, "Log action is required.");
    }

    // Kung may user_id, ang database ang magsasabi kung sino, anong role
    // at anong branch (hindi ang ipinadala ng app).
    if ($logUserId > 0) {
        $uq = $conn->prepare("
            SELECT u.name, u.role, b.name AS branch_name
            FROM users u
            LEFT JOIN branches b ON b.id = u.branch_id
            WHERE u.id = ? LIMIT 1
        ");
        if ($uq) {
            $uq->bind_param("i", $logUserId);
            $uq->execute();
            $urow = $uq->get_result()->fetch_assoc();
            $uq->close();
            if ($urow) {
                $userName = $urow['name'];
                $logRole = strtolower((string)$urow['role']);
                $logBranch = (string)($urow['branch_name'] ?? '');
            } else {
                $logUserId = 0;
            }
        }
    }

    $stmt = $conn->prepare(
        "INSERT INTO activity_logs (`action`, description, user_name, user_id, role, branch_name)
         VALUES (?, ?, ?, NULLIF(?, 0), ?, ?)"
    );

    if (!$stmt) {
        response(false, "Failed to prepare log query: " . $conn->error);
    }

    $stmt->bind_param(
        "sssiss",
        $logAction,
        $description,
        $userName,
        $logUserId,
        $logRole,
        $logBranch
    );

    if (!$stmt->execute()) {
        $error = $stmt->error;
        $stmt->close();
        response(false, "Failed to save log: " . $error);
    }

    $stmt->close();

    response(true, "Log saved successfully.");
}


// ============================================================
// GET LOGS (huling 500) -- Owner/Admin lang
// ============================================================
if ($action === 'get_logs') {

    $actorId = intval($_POST['user_id'] ?? 0);

    $actorRole = getUserRole($conn, $actorId);

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can view activity logs.");
    }

    $logSql = "
        SELECT `action`, description, user_name, user_id, role, branch_name, created_at
        FROM activity_logs
    ";

    // Logs ng mga account ng sarili niyang grupo lang
    $tenantCond = "user_id IN (SELECT id FROM users WHERE owner_id = "
                . intval(getUserOwnerId($conn, $actorId)) . ")";

    // OWNER: lahat sa sarili niyang grupo. Ang mga lumang log na walang
    // user_id ay sa pinakaunang Owner lang.
    $oldLogs = ($actorId === getFirstOwnerId($conn)) ? " OR user_id IS NULL" : "";
    $result = $conn->query(
        $logSql . " WHERE ($tenantCond$oldLogs) ORDER BY id DESC LIMIT 500"
    );

    if (!$result) {
        response(false, "Failed to load logs: " . $conn->error);
    }

    $logs = [];

    while ($row = $result->fetch_assoc()) {
        $logs[] = [
            "action" => $row["action"],
            "description" => $row["description"] ?? '',
            "type" => strtolower($row["action"]),
            "user" => $row["user_name"],
            "userId" => $row["user_id"] === null ? 0 : (int)$row["user_id"],
            "role" => $row["role"] ?? '',
            "branch" => $row["branch_name"] ?? '',
            "created" => $row["created_at"]
        ];
    }

    response(true, "Logs loaded successfully.", ["logs" => $logs]);
}


// ============================================================
// CHANGE PASSWORD
// ============================================================
if ($action === 'change_password') {

    $userId = intval($_POST['user_id'] ?? 0);
    $currentPassword = $_POST['current_password'] ?? '';
    $newPassword = $_POST['new_password'] ?? '';

    if ($userId <= 0) {
        response(false, "Invalid user ID.");
    }

    if ($currentPassword === '' || $newPassword === '') {
        response(false, "Current password and new password are required.");
    }

    if (strlen($newPassword) < 6) {
        response(false, "New password must be at least 6 characters.");
    }

    $stmt = $conn->prepare("SELECT password FROM users WHERE id = ? LIMIT 1");

    if (!$stmt) {
        response(false, "Failed to prepare password query.");
    }

    $stmt->bind_param("i", $userId);
    $stmt->execute();
    $result = $stmt->get_result();

    if ($result->num_rows === 0) {
        $stmt->close();
        response(false, "User account not found.");
    }

    $user = $result->fetch_assoc();
    $stmt->close();

    if (!password_verify($currentPassword, $user['password'])) {
        response(false, "Current password is incorrect.");
    }

    $newHashedPassword = password_hash($newPassword, PASSWORD_DEFAULT);

    $update = $conn->prepare("UPDATE users SET password = ? WHERE id = ?");

    if (!$update) {
        response(false, "Failed to prepare password update.");
    }

    $update->bind_param("si", $newHashedPassword, $userId);

    if (!$update->execute()) {
        $error = $update->error;
        $update->close();
        response(false, "Failed to change password: " . $error);
    }

    $update->close();

    response(true, "Password changed successfully.");
}


// ============================================================
// FORGOT PASSWORD (kahit sino, basta naka-register ang email)
//   1) forgot_request: magpapadala ng 6-digit code sa email
//   2) forgot_reset  : ilagay ang code + bagong password
// Ang code ay valid ng 10 minuto at hanggang 5 subok lang.
// Optional sa config.php: 'mail_from' => 'no-reply@iyong-domain.com'
// ============================================================
// ============================================================
// FORGOT PASSWORD: mag-request sa Admin/Owner na palitan ang password
// Walang login na kailangan. Parehong sagot kahit hindi registered ang email.
// ============================================================
if ($action === 'forgot_request') {

    $email = trim($_POST['email'] ?? '');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
        response(false, "Please enter a valid email address.");
    }

    $fq = $conn->prepare("SELECT id, role, owner_id, branch_id FROM users WHERE email = ? LIMIT 1");

    if (!$fq) {
        response(false, "Failed to prepare request.");
    }

    $fq->bind_param("s", $email);
    $fq->execute();
    $fu = $fq->get_result()->fetch_assoc();
    $fq->close();

    // Ang Owner ay walang ibang mag-reset sa app; hindi gagawa ng request
    if ($fu && strtolower($fu['role']) !== 'owner') {

        $fid = intval($fu['id']);
        $pend = $conn->query("SELECT id FROM password_requests WHERE user_id = $fid AND status = 'pending' LIMIT 1");

        if ($pend && $pend->num_rows === 0) {
            $fo = $fu['owner_id'] === null ? null : intval($fu['owner_id']);
            $fb = $fu['branch_id'] === null ? null : intval($fu['branch_id']);
            $ins = $conn->prepare("INSERT INTO password_requests (user_id, owner_id, branch_id) VALUES (?, ?, ?)");

            if ($ins) {
                $ins->bind_param("iii", $fid, $fo, $fb);
                $ins->execute();
                $ins->close();
            }
        }
    }

    // Tuloy sa pagpapadala ng code sa email ng mismong user (sa ibaba)
}

// ============================================================
// LIST PASSWORD REQUESTS (Owner/Admin)
// Owner: lahat sa grupo niya. Admin: staff ng branch niya.
// ============================================================
if ($action === 'list_password_requests') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $actorRole = getUserRole($conn, $actorId);

    if (!isManagerRole($actorRole)) {
        response(true, "Requests loaded.", ["requests" => []]);
    }

    $ao = getUserOwnerId($conn, $actorId);
    $sql = "
        SELECT r.id, r.created_at, u.id AS uid, u.name, u.email, u.role, b.name AS branch
        FROM password_requests r
        JOIN users u ON u.id = r.user_id
        LEFT JOIN branches b ON b.id = u.branch_id
        WHERE r.status = 'pending' AND u.owner_id = ?
    ";

    $stmt = $conn->prepare($sql . " ORDER BY r.id DESC");

    if (!$stmt) {
        response(false, "Failed to load requests: " . $conn->error);
    }

    $stmt->bind_param("i", $ao);

    $stmt->execute();
    $res = $stmt->get_result();
    $stmt->close();

    $reqs = [];

    while ($r = $res->fetch_assoc()) {
        $reqs[] = [
            "id" => (int)$r['id'],
            "userId" => (int)$r['uid'],
            "name" => $r['name'],
            "email" => $r['email'],
            "role" => $r['role'],
            "branch" => $r['branch'] ?? '',
            "createdAt" => $r['created_at']
        ];
    }

    response(true, "Requests loaded.", ["requests" => $reqs]);
}

// I-dismiss ang request (hindi na kailangan)
if ($action === 'dismiss_password_request') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $reqId = intval($_POST['request_id'] ?? 0);

    if (!isManagerRole(getUserRole($conn, $actorId))) {
        response(false, "Not allowed.");
    }

    $ao = getUserOwnerId($conn, $actorId);
    $dq = $conn->prepare("UPDATE password_requests SET status = 'dismissed' WHERE id = ? AND owner_id = ?");

    if ($dq) {
        $dq->bind_param("ii", $reqId, $ao);
        $dq->execute();
        $dq->close();
    }

    response(true, "Request dismissed.");
}

// ============================================================
// RESET STAFF PASSWORD (Owner/Admin)
// Owner: Admin at Staff ng grupo niya. Admin: Staff ng branch niya.
// ============================================================
if ($action === 'reset_staff_password') {

    $actorId = intval($_POST['user_id'] ?? 0);
    $targetId = intval($_POST['target_id'] ?? 0);
    $newPass = (string)($_POST['new_password'] ?? '');

    $actorRole = getUserRole($conn, $actorId);

    if (!isOwnerRole($actorRole)) {
        response(false, "Only the Owner can reset passwords.");
    }

    if ($targetId <= 0 || $targetId === $actorId) {
        response(false, "Invalid account.");
    }

    if (strlen($newPass) < 6) {
        response(false, "Password must be at least 6 characters.");
    }

    $targetRole = getUserRole($conn, $targetId);

    if ($targetRole !== 'staff') {
        response(false, "You can only reset the password of Staff.");
    }

    if (getUserOwnerId($conn, $targetId) !== getUserOwnerId($conn, $actorId)) {
        response(false, "This account is not under you.");
    }

    $hash = password_hash($newPass, PASSWORD_DEFAULT);
    $up = $conn->prepare("UPDATE users SET password = ? WHERE id = ?");

    if (!$up) {
        response(false, "Failed to prepare password reset.");
    }

    $up->bind_param("si", $hash, $targetId);

    if (!$up->execute()) {
        $err = $up->error;
        $up->close();
        response(false, "Failed to reset password: " . $err);
    }

    $up->close();

    // Tapos na ang request(s) ng account na ito
    $conn->query("UPDATE password_requests SET status = 'done' WHERE user_id = " . intval($targetId) . " AND status = 'pending'");

    response(true, "Password reset successfully.");
}

if ($action === 'forgot_request') {

    $email = strtolower(trim($_POST['email'] ?? ''));

    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
        response(false, "Please enter a valid email address.");
    }

    // Parehong sagot kahit hindi naka-register ang email (para hindi
    // mahulaan kung sinong may account)
    $generic = "If this email is registered, a 6-digit code was sent to it. "
             . "The code expires in 10 minutes.";

    $uq = $conn->prepare("SELECT id, name FROM users WHERE email = ? LIMIT 1");

    if (!$uq) {
        response(false, "Failed to prepare account check.");
    }

    $uq->bind_param("s", $email);
    $uq->execute();
    $acct = $uq->get_result()->fetch_assoc();
    $uq->close();

    if (!$acct) {
        response(true, $generic);
    }

    // Isang code kada 60 segundo lang
    $rl = $conn->prepare(
        "SELECT TIMESTAMPDIFF(SECOND, created_at, NOW()) AS age
         FROM password_resets WHERE email = ? LIMIT 1"
    );

    if ($rl) {
        $rl->bind_param("s", $email);
        $rl->execute();
        $last = $rl->get_result()->fetch_assoc();
        $rl->close();

        if ($last && intval($last['age']) < 60) {
            response(true, $generic);
        }
    }

    $code = (string)random_int(100000, 999999);
    $codeHash = password_hash($code, PASSWORD_DEFAULT);

    $ins = $conn->prepare(
        "INSERT INTO password_resets (email, code_hash, attempts, created_at, expires_at)
         VALUES (?, ?, 0, NOW(), DATE_ADD(NOW(), INTERVAL 10 MINUTE))
         ON DUPLICATE KEY UPDATE
            code_hash = VALUES(code_hash),
            attempts = 0,
            created_at = NOW(),
            expires_at = VALUES(expires_at)"
    );

    if (!$ins) {
        response(false, "Failed to prepare reset code: " . $conn->error);
    }

    $ins->bind_param("ss", $email, $codeHash);

    if (!$ins->execute()) {
        $err = $ins->error;
        $ins->close();
        response(false, "Failed to create reset code: " . $err);
    }

    $ins->close();

    // Ipadala ang code sa email (EmailJS)
    $mailName = preg_replace('/[\r\n]+/', ' ', (string)$acct['name']);
    $sendError = '';
    $sent = sendEmailJs(
        $config,
        $email,
        $mailName,
        "ReceiScan password reset code",
        "Your ReceiScan password reset code is: " . $code . "\n\n"
        . "It expires in 10 minutes. If you did not ask for this, you can ignore this email.",
        $sendError
    );

    if (!$sent) {
        $del = $conn->prepare("DELETE FROM password_resets WHERE email = ?");
        if ($del) {
            $del->bind_param("s", $email);
            $del->execute();
            $del->close();
        }
        response(false, "Unable to send the email: " . $sendError);
    }

    response(true, $generic);
}


if ($action === 'forgot_reset') {

    $email = strtolower(trim($_POST['email'] ?? ''));
    $code = trim($_POST['code'] ?? '');
    $newPassword = (string)($_POST['new_password'] ?? '');

    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
        response(false, "Please enter a valid email address.");
    }

    if (!preg_match('/^\d{6}$/', $code)) {
        response(false, "Please enter the 6-digit code.");
    }

    if (strlen($newPassword) < 6) {
        response(false, "New password must be at least 6 characters.");
    }

    $rq = $conn->prepare(
        "SELECT code_hash, attempts, (expires_at < NOW()) AS expired
         FROM password_resets WHERE email = ? LIMIT 1"
    );

    if (!$rq) {
        response(false, "Failed to prepare code check.");
    }

    $rq->bind_param("s", $email);
    $rq->execute();
    $row = $rq->get_result()->fetch_assoc();
    $rq->close();

    if (!$row) {
        response(false, "Invalid or expired code. Please request a new one.");
    }

    if (intval($row['expired']) === 1 || intval($row['attempts']) >= 5) {
        $del = $conn->prepare("DELETE FROM password_resets WHERE email = ?");
        if ($del) {
            $del->bind_param("s", $email);
            $del->execute();
            $del->close();
        }
        response(false, "This code is no longer valid. Please request a new one.");
    }

    if (!password_verify($code, $row['code_hash'])) {
        $at = $conn->prepare("UPDATE password_resets SET attempts = attempts + 1 WHERE email = ?");
        if ($at) {
            $at->bind_param("s", $email);
            $at->execute();
            $at->close();
        }
        response(false, "Wrong code. Please check the code in your email.");
    }

    $hashed = password_hash($newPassword, PASSWORD_DEFAULT);
    $up = $conn->prepare("UPDATE users SET password = ? WHERE email = ?");

    if (!$up) {
        response(false, "Failed to prepare password update.");
    }

    $up->bind_param("ss", $hashed, $email);

    if (!$up->execute()) {
        $err = $up->error;
        $up->close();
        response(false, "Failed to change password: " . $err);
    }

    $up->close();

    // Tapos na ang password request ng account na ito (kung meron)
    $conn->query(
        "UPDATE password_requests SET status = 'done'
         WHERE status = 'pending' AND user_id IN (SELECT id FROM users WHERE email = '" . $conn->real_escape_string($email) . "')"
    );

    // Gamit na ang code; burahin
    $del = $conn->prepare("DELETE FROM password_resets WHERE email = ?");
    if ($del) {
        $del->bind_param("s", $email);
        $del->execute();
        $del->close();
    }

    response(true, "Password changed successfully. You can now log in.");
}


// ============================================================
// UNKNOWN ACTION
// ============================================================
response(false, "Unknown action: " . $action);