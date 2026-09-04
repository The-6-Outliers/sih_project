import { initializeApp } from 'firebase/app'
import { getAuth } from 'firebase/auth'
import { getFirestore, enableMultiTabIndexedDbPersistence } from 'firebase/firestore'
import { getStorage } from 'firebase/storage'

const firebaseConfig = {
  apiKey: 'AIzaSyDl5ZcplR1Q1QQWrx3F-T6IyyzwH5vKzIs',
  authDomain: 'sih-2026-b6739.firebaseapp.com',
  projectId: 'sih-2026-b6739',
  storageBucket: 'sih-2026-b6739.firebasestorage.app',
  messagingSenderId: '87907194843',
  appId: '1:87907194843:web:1f6c9803c026b8c16f79fe',
  measurementId: 'G-X4CKXYQ3EG',
}

const app = initializeApp(firebaseConfig)
export const auth = getAuth(app)
export const db = getFirestore(app)
export const storage = getStorage(app)
enableMultiTabIndexedDbPersistence(db).catch(() => {})
export default app
