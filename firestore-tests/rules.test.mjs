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
    await setDoc(doc(f, 'items/one'), { title: 'חלב', done: false, by: 'alex', byName: 'Alex' });
  });
});

const item = { title: 'לחם', done: false, by: 'alex', byName: 'Alex', createdAt: new Date() };

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

test('items: allowed read and write, strangers nothing', async () => {
  await assertSucceeds(getDoc(doc(db(ALEX), 'items/one')));
  await assertSucceeds(addDoc(collection(db(ALEX), 'items'), item));
  await assertFails(getDoc(doc(db(STRANGER), 'items/one')));
  await assertFails(addDoc(collection(db(STRANGER), 'items'), item));
  await assertFails(addDoc(collection(db(null), 'items'), item));
});

test('items: shape is enforced', async () => {
  await assertFails(addDoc(collection(db(ALEX), 'items'), { ...item, extra: 1 }));
  await assertFails(addDoc(collection(db(ALEX), 'items'), { ...item, title: '' }));
  await assertFails(addDoc(collection(db(ALEX), 'items'), { ...item, title: 'x'.repeat(501) }));
  await assertFails(addDoc(collection(db(ALEX), 'items'), { ...item, title: 5 }));
});

test('items: update touches only title and done; delete for the allowed', async () => {
  await assertSucceeds(updateDoc(doc(db(ALEX), 'items/one'), { done: true }));
  await assertSucceeds(updateDoc(doc(db(ALEX), 'items/one'), { title: 'חלב 3%' }));
  await assertFails(updateDoc(doc(db(ALEX), 'items/one'), { by: 'someone' }));
  await assertFails(updateDoc(doc(db(STRANGER), 'items/one'), { done: true }));
  await assertFails(deleteDoc(doc(db(STRANGER), 'items/one')));
  await assertSucceeds(deleteDoc(doc(db(ALEX), 'items/one')));
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
