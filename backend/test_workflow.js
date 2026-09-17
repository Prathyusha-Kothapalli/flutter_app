/**
 * End-to-End Test Suite for Video Review and Approval Workflow
 * Tests all rules, roles, state machine transitions, rejection reasons, audit history, and vendor isolation.
 */

const http = require('http');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });
const pool = require('./src/database/connection');

const BASE_URL = `http://localhost:${process.env.PORT || 5000}`;

function request(method, path, body = null, headers = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE_URL);
    const options = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method: method,
      headers: {
        'Content-Type': 'application/json',
        ...headers,
      },
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          const parsed = data ? JSON.parse(data) : {};
          resolve({ status: res.statusCode, body: parsed });
        } catch (e) {
          resolve({ status: res.statusCode, raw: data });
        }
      });
    });

    req.on('error', reject);
    if (body) {
      req.write(JSON.stringify(body));
    }
    req.end();
  });
}

async function runTests() {
  console.log('====================================================');
  console.log('🚀 STARTING VIDEO REVIEW & APPROVAL WORKFLOW TESTS');
  console.log('====================================================\n');

  let passed = 0;
  let failed = 0;

  function assert(condition, message) {
    if (condition) {
      console.log(`  ✅ PASS: ${message}`);
      passed++;
    } else {
      console.error(`  ❌ FAIL: ${message}`);
      failed++;
    }
  }

  try {
    // 0. Database connectivity check
    const dbRes = await pool.query('SELECT NOW()');
    assert(dbRes.rows.length > 0, 'Database is connected');

    // 1. Authenticate Admin
    console.log('\n--- Test Phase 1: Authentication & Role Setup ---');
    const adminRes = await request('POST', '/api/v1/auth/login', {
      email: 'admin@gmail.com',
      password: 'admin123',
    });
    const adminToken = adminRes.body?.data?.accessToken || adminRes.body?.data?.token;
    assert(adminRes.status === 200 && !!adminToken, 'Admin login successful');

    // 2. Create Vendor A and Vendor B
    const vendorAEmail = `vendor_a_${Date.now()}@test.com`;
    const vendorARes = await request('POST', '/api/v1/vendors', {
      company_name: 'Vendor A Logistics',
      contact_person: 'Alice Vendor',
      email: vendorAEmail,
      phone: '+1234567890',
      password: 'Password123!',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(vendorARes.status === 201 || vendorARes.status === 200, 'Vendor A created');
    const vendorAId = vendorARes.body?.data?.id;
    const vendorACode = vendorARes.body?.data?.vendor_code;

    const vendorBEmail = `vendor_b_${Date.now()}@test.com`;
    const vendorBRes = await request('POST', '/api/v1/vendors', {
      company_name: 'Vendor B Enterprise',
      contact_person: 'Bob Vendor',
      email: vendorBEmail,
      phone: '+1987654321',
      password: 'Password123!',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(vendorBRes.status === 201 || vendorBRes.status === 200, 'Vendor B created');
    const vendorBId = vendorBRes.body?.data?.id;
    const vendorBCode = vendorBRes.body?.data?.vendor_code;

    // Login as Vendor A & Vendor B
    const vALogin = await request('POST', '/api/v1/auth/login', { email: vendorAEmail, password: 'Password123!' });
    const vendorAToken = vALogin.body?.data?.accessToken || vALogin.body?.data?.token;
    assert(vALogin.status === 200 && !!vendorAToken, 'Vendor A login successful');

    const vBLogin = await request('POST', '/api/v1/auth/login', { email: vendorBEmail, password: 'Password123!' });
    const vendorBToken = vBLogin.body?.data?.accessToken || vBLogin.body?.data?.token;
    assert(vBLogin.status === 200 && !!vendorBToken, 'Vendor B login successful');

    // 3. Register Candidate under Vendor A
    const candEmail = `cand_a_${Date.now()}@test.com`;
    const candSignup = await request('POST', '/api/v1/auth/signup', {
      full_name: 'John Candidate',
      name: 'John Candidate',
      email: candEmail,
      phone: '+1555123456',
      password: 'Password123!',
      vendor_code: vendorACode,
    });
    assert(candSignup.status === 201 || candSignup.status === 200, 'Candidate under Vendor A registered');
    const candToken = candSignup.body?.data?.accessToken || candSignup.body?.data?.token;
    const candId = candSignup.body?.data?.user?.id || candSignup.body?.data?.candidate?.id;

    // 4. Authenticate QC Reviewer (Ensure test QC user exists)
    const bcrypt = require('bcryptjs');
    const qcHash = await bcrypt.hash('Password123!', 10);
    await pool.query(`
      INSERT INTO users (id, email, password_hash, full_name, role, is_active)
      VALUES ('30000000-0000-4000-8000-000000000099', 'test_qc@test.com', $1, 'Test QC Reviewer', 'qc_team', TRUE)
      ON CONFLICT (email) DO UPDATE SET password_hash = $1, role = 'qc_team', is_active = TRUE
    `, [qcHash]);

    const qcLogin = await request('POST', '/api/v1/auth/login', {
      email: 'test_qc@test.com',
      password: 'Password123!',
    });
    const qcToken = qcLogin.body?.data?.accessToken || qcLogin.body?.data?.token;
    assert(qcLogin.status === 200 && !!qcToken, 'QC Reviewer login successful');

    console.log('\n--- Test Phase 2: Happy Path Workflow (Candidate -> QC -> Admin -> Final Approved) ---');
    // Upload video 1 directly to database/service with candidate auth
    const vid1Res = await pool.query(
      `INSERT INTO videos (candidate_id, vendor_id, title, duration, file_name, s3_url, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
      [candId, vendorAId, 'Candidate 1 Kitchen Walkthrough', 120, 'test1.mp4', 'https://storage.test/test1.mp4', 'QC_PENDING']
    );
    const video1 = vid1Res.rows[0];
    assert(video1.status === 'QC_PENDING', 'Initial video status is QC_PENDING');
    assert(video1.vendor_id === vendorAId, 'Video is correctly linked to Vendor A');

    // Candidate attempts unauthorized status modification
    const candTamper = await request('PATCH', `/api/v1/videos/${video1.id}/status`, {
      status: 'FINAL_APPROVED',
    }, { Authorization: `Bearer ${candToken}` });
    assert(candTamper.status === 403, 'Candidate cannot directly change video status (HTTP 403)');

    // QC attempts illegal direct final approval
    const qcTamper = await request('PATCH', `/api/v1/videos/${video1.id}/status`, {
      status: 'FINAL_APPROVED',
    }, { Authorization: `Bearer ${qcToken}` });
    assert(qcTamper.status === 403, 'QC reviewer cannot set status to FINAL_APPROVED (HTTP 403)');

    // QC reviews and approves video
    const qcApprove = await request('POST', '/api/v1/qc-reviews', {
      video_id: video1.id,
      status: 'approved',
      reviewer_name: 'QC Inspector Jane',
      audio_score: 4.5,
      lighting_score: 4.0,
      framing_score: 5.0,
      env_match_score: 4.8,
    }, { Authorization: `Bearer ${qcToken}` });
    assert(qcApprove.status === 201 || qcApprove.status === 200, 'QC approve submitted successfully');

    // Verify video status is now ADMIN_PENDING
    const vid1Check = await pool.query('SELECT * FROM videos WHERE id = $1', [video1.id]);
    assert(vid1Check.rows[0].status === 'ADMIN_PENDING', 'Video transitioned to ADMIN_PENDING after QC approval');
    assert(vid1Check.rows[0].qc_decision === 'QC_APPROVED', 'qc_decision recorded');

    // Verify review history table has audit entry
    const history1 = await pool.query('SELECT * FROM video_review_history WHERE video_id = $1 ORDER BY created_at DESC', [video1.id]);
    assert(history1.rows.length >= 1, 'Audit log created in video_review_history');
    assert(history1.rows[0].to_status === 'ADMIN_PENDING', 'Audit log shows transition to ADMIN_PENDING');

    // Admin checks QC-Approved queue
    const adminQueue = await request('GET', '/api/v1/admins/qc-approved', null, { Authorization: `Bearer ${adminToken}` });
    assert(adminQueue.status === 200, 'Admin can fetch QC-Approved queue');
    const queueList = adminQueue.body?.data?.items || (Array.isArray(adminQueue.body?.data) ? adminQueue.body?.data : []);
    assert(queueList.some(v => v.id === video1.id), 'Video 1 appears in Admin review queue');

    // Admin approves video
    const adminApprove = await request('POST', `/api/v1/admins/videos/${video1.id}/approve`, {
      comments: 'Excellent quality video, all criteria met',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(adminApprove.status === 200, 'Admin final approve succeeded');

    // Verify video status is now FINAL_APPROVED
    const vid1Final = await pool.query('SELECT * FROM videos WHERE id = $1', [video1.id]);
    assert(vid1Final.rows[0].status === 'FINAL_APPROVED', 'Video transitioned to FINAL_APPROVED');
    assert(vid1Final.rows[0].admin_decision === 'FINAL_APPROVED', 'admin_decision recorded');

    // Verify full audit history preserved
    const historyFinal = await pool.query('SELECT * FROM video_review_history WHERE video_id = $1 ORDER BY created_at ASC', [video1.id]);
    assert(historyFinal.rows.length >= 2, 'Full review history preserved (both QC and Admin actions)');

    console.log('\n--- Test Phase 3: QC Rejection Flow & Validation ---');
    // Upload video 2
    const vid2Res = await pool.query(
      `INSERT INTO videos (candidate_id, vendor_id, title, duration, file_name, s3_url, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
      [candId, vendorAId, 'Candidate 1 Living Room Recording', 90, 'test2.mp4', 'https://storage.test/test2.mp4', 'QC_PENDING']
    );
    const video2 = vid2Res.rows[0];

    // QC attempts reject without reason
    const qcRejectNoReason = await request('POST', '/api/v1/qc-reviews', {
      video_id: video2.id,
      status: 'rejected',
      reject_reason: '',
    }, { Authorization: `Bearer ${qcToken}` });
    assert(qcRejectNoReason.status === 400, 'QC reject without reason is rejected with HTTP 400');

    // QC rejects with valid reason
    const qcRejectWithReason = await request('POST', '/api/v1/qc-reviews', {
      video_id: video2.id,
      status: 'rejected',
      reject_reason: 'Audio clarity is too low; background noise exceeds threshold.',
    }, { Authorization: `Bearer ${qcToken}` });
    assert(qcRejectWithReason.status === 201 || qcRejectWithReason.status === 200, 'QC reject with reason succeeded');

    // Verify video 2 status is QC_REJECTED and not deleted
    const vid2Check = await pool.query('SELECT * FROM videos WHERE id = $1', [video2.id]);
    assert(vid2Check.rows.length === 1, 'Rejected video record is NOT deleted from database');
    assert(vid2Check.rows[0].status === 'QC_REJECTED', 'Video transitioned to QC_REJECTED');
    assert(vid2Check.rows[0].qc_rejection_reason.includes('Audio clarity is too low'), 'QC rejection reason stored in database');

    // Verify video 2 does NOT appear in Admin queue
    const adminQueue2 = await request('GET', '/api/v1/admins/qc-approved', null, { Authorization: `Bearer ${adminToken}` });
    const queueList2 = adminQueue2.body?.data?.items || (Array.isArray(adminQueue2.body?.data) ? adminQueue2.body?.data : []);
    assert(!queueList2.some(v => v.id === video2.id), 'QC_REJECTED video does NOT appear in Admin approval queue');

    console.log('\n--- Test Phase 4: Admin Rejection Flow & Validation ---');
    // Upload video 3
    const vid3Res = await pool.query(
      `INSERT INTO videos (candidate_id, vendor_id, title, duration, file_name, s3_url, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
      [candId, vendorAId, 'Candidate 1 Office Space', 110, 'test3.mp4', 'https://storage.test/test3.mp4', 'QC_PENDING']
    );
    const video3 = vid3Res.rows[0];

    // QC approves video 3
    await request('POST', '/api/v1/qc-reviews', {
      video_id: video3.id,
      status: 'approved',
      reviewer_name: 'QC Specialist',
    }, { Authorization: `Bearer ${qcToken}` });

    // Admin attempts reject without reason
    const adminRejectNoReason = await request('POST', `/api/v1/admins/videos/${video3.id}/reject`, {
      reason: '',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(adminRejectNoReason.status === 400, 'Admin reject without reason is rejected with HTTP 400');

    // Admin rejects with reason
    const adminRejectWithReason = await request('POST', `/api/v1/admins/videos/${video3.id}/reject`, {
      reason: 'Environment does not match dataset requirements for office setting.',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(adminRejectWithReason.status === 200, 'Admin reject with reason succeeded');

    const vid3Check = await pool.query('SELECT * FROM videos WHERE id = $1', [video3.id]);
    assert(vid3Check.rows.length === 1, 'Admin rejected video is NOT deleted from database');
    assert(vid3Check.rows[0].status === 'ADMIN_REJECTED', 'Video transitioned to ADMIN_REJECTED');
    assert(vid3Check.rows[0].admin_rejection_reason.includes('Environment does not match'), 'Admin rejection reason stored in database');

    console.log('\n--- Test Phase 5: State Machine Illegal Transition Validation ---');
    // Upload video 4
    const vid4Res = await pool.query(
      `INSERT INTO videos (candidate_id, vendor_id, title, duration, file_name, s3_url, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
      [candId, vendorAId, 'Candidate 1 Backyard', 60, 'test4.mp4', 'https://storage.test/test4.mp4', 'QC_PENDING']
    );
    const video4 = vid4Res.rows[0];

    // Attempt direct transition from QC_PENDING to FINAL_APPROVED via video service
    const illegalJump = await request('PATCH', `/api/v1/videos/${video4.id}/status`, {
      status: 'FINAL_APPROVED',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(illegalJump.status === 400, 'Cannot skip QC review (QC_PENDING -> FINAL_APPROVED rejected with HTTP 400)');

    // Attempt transition from QC_REJECTED to FINAL_APPROVED
    const illegalRejToApp = await request('PATCH', `/api/v1/videos/${video2.id}/status`, {
      status: 'FINAL_APPROVED',
    }, { Authorization: `Bearer ${adminToken}` });
    assert(illegalRejToApp.status === 400, 'Cannot approve QC_REJECTED video (QC_REJECTED -> FINAL_APPROVED rejected with HTTP 400)');

    console.log('\n--- Test Phase 6: Strict Vendor Data Isolation ---');
    // Vendor A queries videos
    const vAVideos = await request('GET', '/api/v1/videos', null, { Authorization: `Bearer ${vendorAToken}` });
    const vAList = vAVideos.body?.data?.items || (Array.isArray(vAVideos.body?.data) ? vAVideos.body?.data : []);
    assert(vAVideos.status === 200, 'Vendor A can fetch videos');
    assert(vAList.some(v => v.id === video1.id), 'Vendor A sees video 1 belonging to their candidate');
    assert(vAList.some(v => v.id === video2.id), 'Vendor A sees rejected video 2 with reason');

    // Vendor B queries videos
    const vBVideos = await request('GET', '/api/v1/videos', null, { Authorization: `Bearer ${vendorBToken}` });
    const vBList = vBVideos.body?.data?.items || (Array.isArray(vBVideos.body?.data) ? vBVideos.body?.data : []);
    assert(vBVideos.status === 200, 'Vendor B can fetch videos');
    assert(!vBList.some(v => v.id === video1.id), 'Vendor B CANNOT see Vendor A video 1');
    assert(!vBList.some(v => v.id === video2.id), 'Vendor B CANNOT see Vendor A video 2');

    // Vendor B queries candidates
    const vBCandidates = await request('GET', '/api/v1/candidates', null, { Authorization: `Bearer ${vendorBToken}` });
    const vBCandList = vBCandidates.body?.data?.items || (Array.isArray(vBCandidates.body?.data) ? vBCandidates.body?.data : []);
    assert(!vBCandList.some(c => c.id === candId || c.email === candEmail), 'Vendor B CANNOT see Vendor A candidates');

    console.log('\n====================================================');
    console.log(`📊 TEST RESULTS: ${passed} PASSED, ${failed} FAILED`);
    console.log('====================================================\n');

    process.exit(failed > 0 ? 1 : 0);
  } catch (err) {
    console.error('❌ Test execution error:', err);
    process.exit(1);
  }
}

runTests();
