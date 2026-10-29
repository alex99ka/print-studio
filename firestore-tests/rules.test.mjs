// Every allow and deny path in ../firestore.rules, against the emulator.
// Run: npm test (from this folder; needs Java 21 and the Firebase CLI).
import { after, before, beforeEach, test } from 'node:test';
import { readFileSync } from 'node:fs';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { addDoc, collection, deleteDoc, doc, getDoc, setDoc, updateDoc } from 'firebase/firestore';

let env;
const ALEX = { uid: 'alex', email: 'alex@example.com', email_verified: true };
const STRANGER = { uid: 'stranger', email: 'x@example.com', email_verified: true };
const UNVERIFIED = { uid: 'fake', email: 'alex2@example.com', email_verified: false };

const db = (who) =>
  who ? env.authenticatedContext(who.uid, { email: who.email, email_verified: who.email_verified }).firestore()
      : env.unauthenticatedContext().firestore();

const customer = { name: 'INTERVIEW', lang: 'he', portalToken: 'x'.repeat(22), createdAt: new Date() };
const request = { customerId: 'c1', customerName: 'INTERVIEW', title: 'אלכס ❤ אביטל', qty: 2, status: 'draft',
  latestVersion: 0, createdAt: new Date(), updatedAt: new Date() };
const quote = { requestId: 'draft', customerId: 'c1', unit: 18000, qty: 2, vatPercent: 18, note: '', createdAt: new Date(), by: 'alex' };
const comment = { requestId: 'draft', customerId: 'c1', versionId: 'v2', versionN: 1, from: 'studio', text: 'הלב הוגדל', pin: null, createdAt: new Date() };

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-print-studio',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(() => env.cleanup());
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const f = ctx.firestore();
    await setDoc(doc(f, 'config/app'), { minVersion: '1.0.0' });
    await setDoc(doc(f, 'config/access'), {
      emails: ['alex@example.com', 'alex2@example.com'],
      earlyUsers: ['alex@example.com'],
    });
    await setDoc(doc(f, 'customers/c1'), { name: 'INTERVIEW', lang: 'he', portalToken: 't'.repeat(22) });
    await setDoc(doc(f, 'requests/draft'), { ...request, status: 'draft' });
    await setDoc(doc(f, 'requests/done'), { ...request, status: 'approved', publishedVersionId: 'v1', quoteId: 'q1' });
    await setDoc(doc(f, 'versions/v1'), { requestId: 'done', customerId: 'c1', n: 1, state: 'approved', note: '' });
    await setDoc(doc(f, 'versions/v2'), { requestId: 'draft', customerId: 'c1', n: 1, state: 'draft', note: '' });
    await setDoc(doc(f, 'versions/v3'), { requestId: 'draft', customerId: 'c1', n: 2, state: 'draft', note: '' });
    await setDoc(doc(f, 'comments/client'), { requestId: 'done', from: 'client', text: 'x' });
  });
});


test('config/app is public, read-only', async () => {
  await assertSucceeds(getDoc(doc(db(null), 'config/app')));
  await assertFails(setDoc(doc(db(ALEX), 'config/app'), { minVersion: '0.0.0' }));
});

test('config/access: allowed read it, nobody else, nobody writes', async () => {
  await assertSucceeds(getDoc(doc(db(ALEX), 'config/access')));
  await assertFails(getDoc(doc(db(STRANGER), 'config/access')));
  await assertFails(getDoc(doc(db(null), 'config/access')));
  await assertFails(getDoc(doc(db(UNVERIFIED), 'config/access')));
  await assertFails(setDoc(doc(db(ALEX), 'config/access'), { emails: ['x@example.com'] }));
});

test('users: own profile only, known fields only', async () => {
  await assertSucceeds(setDoc(doc(db(ALEX), 'users/alex'), { name: 'Alex', email: ALEX.email }));
  await assertSucceeds(getDoc(doc(db(ALEX), 'users/alex')));
  await assertFails(setDoc(doc(db(ALEX), 'users/other'), { name: 'x' }));
  await assertFails(getDoc(doc(db(ALEX), 'users/other')));
  await assertFails(setDoc(doc(db(ALEX), 'users/alex'), { admin: true }));
  await assertFails(setDoc(doc(db(STRANGER), 'users/stranger'), { name: 'x' }));
  await assertFails(deleteDoc(doc(db(ALEX), 'users/alex')));
});

test('studio collections: allowed only', async () => {
  for (const path of ['customers/c1', 'requests/draft', 'versions/v1', 'comments/client']) {
    await assertSucceeds(getDoc(doc(db(ALEX), path)));
    await assertFails(getDoc(doc(db(STRANGER), path)));
    await assertFails(getDoc(doc(db(null), path)));
  }
  await assertFails(addDoc(collection(db(STRANGER), 'customers'), customer));
  await assertFails(addDoc(collection(db(null), 'requests'), request));
});

test('customers: shape, and a portal token long enough not to guess', async () => {
  await assertSucceeds(addDoc(collection(db(ALEX), 'customers'), customer));
  await assertFails(addDoc(collection(db(ALEX), 'customers'), { ...customer, portalToken: 'short' }));
  await assertFails(addDoc(collection(db(ALEX), 'customers'), { ...customer, lang: 'fr' }));
  await assertFails(addDoc(collection(db(ALEX), 'customers'), { ...customer, name: '' }));
  await assertFails(addDoc(collection(db(ALEX), 'customers'), { ...customer, extra: 1 }));
  await assertSucceeds(updateDoc(doc(db(ALEX), 'customers/c1'), { portalToken: 'n'.repeat(22) }));
});

test("requests: created as drafts, approval fields are the server's", async () => {
  await assertSucceeds(addDoc(collection(db(ALEX), 'requests'), request));
  await assertFails(addDoc(collection(db(ALEX), 'requests'), { ...request, status: 'approved' }));
  await assertFails(addDoc(collection(db(ALEX), 'requests'), { ...request, latestVersion: 3 }));
  await assertFails(addDoc(collection(db(ALEX), 'requests'), { ...request, qty: 0 }));
  await assertSucceeds(updateDoc(doc(db(ALEX), 'requests/draft'), { status: 'waiting', publishedVersionId: 'v2', quoteId: 'q', needsReply: false }));
  await assertFails(updateDoc(doc(db(ALEX), 'requests/draft'), { approvedVersionId: 'v2' }));
  await assertFails(updateDoc(doc(db(ALEX), 'requests/draft'), { latestVersion: 9 }));
  await assertFails(updateDoc(doc(db(ALEX), 'requests/draft'), { status: 'lost' }));
});

test('requests: an approved one keeps its version, price and quantity; moves along the pipeline', async () => {
  await assertSucceeds(updateDoc(doc(db(ALEX), 'requests/done'), { status: 'printing' }));
  await assertFails(updateDoc(doc(db(ALEX), 'requests/done'), { quoteId: 'cheaper' }));
  await assertFails(updateDoc(doc(db(ALEX), 'requests/done'), { publishedVersionId: 'v9' }));
  await assertFails(updateDoc(doc(db(ALEX), 'requests/done'), { qty: 5 }));
  await assertFails(deleteDoc(doc(db(ALEX), 'requests/done')));
  await assertSucceeds(deleteDoc(doc(db(ALEX), 'requests/draft')));
});

test("requests: production and guests are the server's, and survive the app's writes", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'requests/gift'),
      { ...request, production: { quote: { units: 105 } }, guests: { names: 2, gifts: 3 } });
  });
  const ref = doc(db(ALEX), 'requests/gift');
  await assertFails(updateDoc(ref, { production: { quote: { units: 1 } } }));
  await assertFails(updateDoc(ref, { 'production.progress': { platesDone: 9 } }));
  await assertFails(updateDoc(ref, { guests: null }));
  await assertFails(addDoc(collection(db(ALEX), 'requests'), { ...request, production: {} }));
  await assertFails(addDoc(collection(db(ALEX), 'requests'), { ...request, guests: {} }));
  // A whole-document set would drop them: refused. update() and set(..., merge) keep them.
  await assertFails(setDoc(ref, { ...request, status: 'waiting' }));
  await assertSucceeds(setDoc(ref, { status: 'waiting' }, { merge: true }));
  await assertSucceeds(updateDoc(ref, { title: 'אורחים', updatedAt: new Date() }));
});

test('versions: only the server creates; the app publishes; approved is frozen', async () => {
  await assertFails(setDoc(doc(db(ALEX), 'versions/new'), { requestId: 'draft', n: 2, state: 'draft' }));
  await assertSucceeds(updateDoc(doc(db(ALEX), 'versions/v2'), { state: 'published', publishedAt: new Date() }));
  await assertFails(updateDoc(doc(db(ALEX), 'versions/v2'), { state: 'approved' }));
  await assertFails(updateDoc(doc(db(ALEX), 'versions/v2'), { n: 7 }));
  await assertFails(updateDoc(doc(db(ALEX), 'versions/v1'), { state: 'published' }));
  await assertFails(deleteDoc(doc(db(ALEX), 'versions/v1')));
  await assertFails(deleteDoc(doc(db(ALEX), 'versions/v2')));  // published: the customer may have seen it
  await assertSucceeds(deleteDoc(doc(db(ALEX), 'versions/v3')));
});

test('quotes: created whole, in agorot, never edited', async () => {
  await assertSucceeds(setDoc(doc(db(ALEX), 'quotes/q1'), quote));
  await assertFails(addDoc(collection(db(ALEX), 'quotes'), { ...quote, unit: 180.5 }));
  await assertFails(addDoc(collection(db(ALEX), 'quotes'), { ...quote, unit: -1 }));
  await assertFails(addDoc(collection(db(ALEX), 'quotes'), { ...quote, vatPercent: 117 }));
  await assertFails(updateDoc(doc(db(ALEX), 'quotes/q1'), { unit: 1 }));
  await assertFails(deleteDoc(doc(db(ALEX), 'quotes/q1')));
});

test('comments: the app writes only as the studio, and deletes only its own', async () => {
  await assertSucceeds(setDoc(doc(db(ALEX), 'comments/mine'), comment));
  await assertFails(addDoc(collection(db(ALEX), 'comments'), { ...comment, from: 'client' }));
  await assertFails(addDoc(collection(db(ALEX), 'comments'), { ...comment, text: '' }));
  await assertFails(updateDoc(doc(db(ALEX), 'comments/mine'), { text: 'edited' }));
  await assertFails(deleteDoc(doc(db(ALEX), 'comments/client')));
  await assertSucceeds(deleteDoc(doc(db(ALEX), 'comments/mine')));
  // Handled: only the mark changes, never the client's words.
  await assertSucceeds(updateDoc(doc(db(ALEX), 'comments/client'), { done: true, doneAt: new Date() }));
  await assertSucceeds(updateDoc(doc(db(ALEX), 'comments/client'), { done: false, doneAt: null }));
  await assertFails(updateDoc(doc(db(ALEX), 'comments/client'), { done: true, text: 'rewritten' }));
  await assertFails(updateDoc(doc(db(ALEX), 'comments/client'), { done: 'yes' }));
});

test('reports: create-only, own uid', async () => {
  const r = collection(db(ALEX), 'reports');
  await assertSucceeds(addDoc(r, { uid: 'alex', text: 'בעיה' }));
  await assertFails(addDoc(r, { uid: 'other', text: 'x' }));
  await assertFails(addDoc(collection(db(STRANGER), 'reports'), { uid: 'stranger', text: 'x' }));
  await assertFails(getDoc(doc(db(ALEX), 'reports/any')));
});

test('anything else is denied', async () => {
  await assertFails(setDoc(doc(db(ALEX), 'secrets/x'), { a: 1 }));
  await assertFails(getDoc(doc(db(ALEX), 'secrets/x')));
});

test('payments: the app records and deletes them, positive whole agorot, never edits', async () => {
  const pay = { requestId: 'done', customerId: 'c1', amount: 21240, method: 'bit', note: 'מקדמה', at: new Date(), createdAt: new Date() };
  await assertSucceeds(setDoc(doc(db(ALEX), 'payments/p1'), pay));
  await assertSucceeds(getDoc(doc(db(ALEX), 'payments/p1')));
  await assertFails(updateDoc(doc(db(ALEX), 'payments/p1'), { amount: 1 }));
  await assertFails(setDoc(doc(db(ALEX), 'payments/p2'), { ...pay, amount: 0 }));
  await assertFails(setDoc(doc(db(ALEX), 'payments/p2'), { ...pay, amount: 1.5 }));
  await assertFails(setDoc(doc(db(ALEX), 'payments/p2'), { ...pay, method: 'crypto' }));
  await assertFails(setDoc(doc(db(ALEX), 'payments/p2'), { ...pay, extra: 1 }));
  await assertFails(setDoc(doc(db(STRANGER), 'payments/p2'), pay));
  await assertFails(getDoc(doc(db(STRANGER), 'payments/p1')));
  await assertSucceeds(deleteDoc(doc(db(ALEX), 'payments/p1')));
});
