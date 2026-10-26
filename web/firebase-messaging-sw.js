// Push notifications for the web app (the iPad, added to its Home Screen).
// Firebase shows a message that arrives while the app is closed. The config
// is the web app's own, the same values as lib/firebase_options.dart (web);
// the SDK version matches FlutterFire's.
importScripts("https://www.gstatic.com/firebasejs/12.19.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/12.19.0/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDLYcFtRQ7-leIsE0_jYnkdkPpDaEIS8fQ",
  appId: "1:256993487907:web:fd6bed594f6ebfe9e89596",
  messagingSenderId: "256993487907",
  projectId: "print-studio-1786a",
  authDomain: "print-studio-1786a.firebaseapp.com",
  storageBucket: "print-studio-1786a.firebasestorage.app",
});
firebase.messaging();
