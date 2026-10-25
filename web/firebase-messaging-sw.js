// Push notifications for the web app (the iPad, added to its Home Screen).
// Firebase shows a message that arrives while the app is closed. The config
// is the web app's own, the same values as lib/firebase_options.dart (web);
// the SDK version matches FlutterFire's.
importScripts("https://www.gstatic.com/firebasejs/12.19.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/12.19.0/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "REPLACE",
  appId: "REPLACE",
  messagingSenderId: "REPLACE",
  projectId: "REPLACE",
  authDomain: "REPLACE.firebaseapp.com",
  storageBucket: "REPLACE.firebasestorage.app",
});
firebase.messaging();
