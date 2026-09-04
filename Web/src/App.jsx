import { cloneElement, useEffect, useState } from "react";
import {
  BrowserRouter,
  NavLink,
  Navigate,
  Route,
  Routes,
  useLocation,
} from "react-router-dom";
import {
  Activity,
  BarChart3,
  Bell,
  BrainCircuit,
  Building2,
  ChevronDown,
  CircleAlert,
  ClipboardCheck,
  FileScan,
  FileText,
  HardHat,
  LayoutDashboard,
  Map as MapIcon,
  Menu,
  MessageSquareWarning,
  Mountain,
  Search,
  ShieldCheck,
  UploadCloud,
  Users,
  X,
} from "lucide-react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import "./App.css";
import MineRiskHeatmap from "./MineRiskHeatmap.jsx";
import { auth, db } from "./firebaseConfig.js";
import {
  createUserWithEmailAndPassword,
  GoogleAuthProvider,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signInWithPopup,
  signOut,
} from "firebase/auth";
import { collection, doc, getDoc, onSnapshot, orderBy, query, serverTimestamp, setDoc } from "firebase/firestore";

const mines = [
  {
    id: "m1",
    name: "Gevra OC",
    subsidiary: "SECL",
    risk: 82,
    status: "High risk",
    production: "2.4M t",
    open: 7,
    color: "#ef6461",
  },
  {
    id: "m2",
    name: "Bokaro & Kargali",
    subsidiary: "CCL",
    risk: 39,
    status: "Monitored",
    production: "1.8M t",
    open: 3,
    color: "#e4a853",
  },
  {
    id: "m3",
    name: "NCL Jayant",
    subsidiary: "NCL",
    risk: 18,
    status: "Compliant",
    production: "3.1M t",
    open: 1,
    color: "#3f9b82",
  },
  {
    id: "m4",
    name: "Talcher Central",
    subsidiary: "MCL",
    risk: 64,
    status: "Elevated",
    production: "2.1M t",
    open: 5,
    color: "#e4a853",
  },
];
const compliance = [
  [
    "DGMS",
    "Coal Mines Regulations, 2017",
    "C-17.04",
    "Gevra OC",
    "Due today",
    "Critical",
  ],
  [
    "MoEFCC",
    "Air quality monitoring report",
    "EC-09.22",
    "Talcher Central",
    "Due in 2d",
    "Elevated",
  ],
  [
    "Labour",
    "Contractor safety training register",
    "L-02.18",
    "Bokaro & Kargali",
    "Due in 6d",
    "Moderate",
  ],
  [
    "DGMS",
    "Roof support inspection log",
    "C-08.11",
    "NCL Jayant",
    "Complete",
    "Low",
  ],
  [
    "MoEFCC",
    "Progressive mine closure plan",
    "EC-01.08",
    "Gevra OC",
    "Overdue 3d",
    "Critical",
  ],
];
const trend = [
  { month: "Apr", compliant: 68, resolved: 42 },
  { month: "May", compliant: 72, resolved: 49 },
  { month: "Jun", compliant: 76, resolved: 55 },
  { month: "Jul", compliant: 71, resolved: 61 },
  { month: "Aug", compliant: 83, resolved: 67 },
  { month: "Sep", compliant: 87, resolved: 74 },
];
const fieldActivity = [
  {
    person: "R. Sahu",
    role: "Safety officer",
    action: "Logged roof support observation",
    mine: "Gevra OC",
    time: "18 min ago",
    tone: "red",
  },
  {
    person: "M. Pradhan",
    role: "Environment lead",
    action: "Submitted air quality reading",
    mine: "Talcher Central",
    time: "42 min ago",
    tone: "green",
  },
  {
    person: "S. Khan",
    role: "Contractor manager",
    action: "Renewed induction register",
    mine: "NCL Jayant",
    time: "1 hr ago",
    tone: "blue",
  },
];
const contractors = [
  {
    name: "Eastern Infra Services",
    mine: "Gevra OC",
    workers: 184,
    training: 91,
    status: "Action needed",
  },
  {
    name: "Bharat Haulage Co.",
    mine: "Talcher Central",
    workers: 96,
    training: 98,
    status: "Compliant",
  },
  {
    name: "Maa Tara Mining",
    mine: "Bokaro & Kargali",
    workers: 72,
    training: 84,
    status: "Review due",
  },
];
const grievances = [
  {
    title: "Dust exposure near haul road 4",
    mine: "Gevra OC",
    owner: "Environment cell",
    status: "Investigating",
    age: "2 days",
  },
  {
    title: "Contractor wage documentation",
    mine: "Bokaro & Kargali",
    owner: "Labour cell",
    status: "Resolved",
    age: "5 days",
  },
  {
    title: "Drinking water point maintenance",
    mine: "Talcher Central",
    owner: "Site admin",
    status: "Open",
    age: "6 hours",
  },
];

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<Auth />} />
        <Route path="/signup" element={<Auth signup />} />
        <Route
          path="*"
          element={
            <Protected>
              <Console />
            </Protected>
          }
        />
      </Routes>
    </BrowserRouter>
  );
}
function Protected({ children }) {
  const [user, setUser] = useState(undefined);
  const [profile, setProfile] = useState(null);
  useEffect(() => onAuthStateChanged(auth, setUser), []);
  useEffect(() => {
    const pending = localStorage.getItem("sih_pending_profile");
    if (!user || !pending) return;
    const profile = JSON.parse(pending);
    saveUserProfile(user, profile.role, profile)
      .then(() => localStorage.removeItem("sih_pending_profile"))
      .catch(() => {});
  }, [user]);
  useEffect(() => {
    if (!user) return;
    getDoc(doc(db, "users", user.uid))
      .then((snapshot) => setProfile(snapshot.exists() ? snapshot.data() : null))
      .catch(() => setProfile(null));
  }, [user]);
  if (user === undefined)
    return <div className="auth-loading">Checking secure access...</div>;
  return user
    ? cloneElement(children, { user, profile })
    : <Navigate to="/login" replace />;
}
async function saveUserProfile(user, role, details = {}) {
  await setDoc(
    doc(db, "users", user.uid),
    {
      uid: user.uid,
      email: user.email,
      displayName: user.displayName || user.email?.split("@")[0] || "User",
      role,
      mineId: role === "inspector" ? "m1" : null,
      ...details,
      updatedAt: serverTimestamp(),
    },
    { merge: true },
  );
}
function withTimeout(promise, milliseconds = 15000) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("Firebase is not responding. Check your internet connection and Firebase authorized domains.")), milliseconds),
    ),
  ]);
}
function readableAuthError(authError) {
  const messages = {
    "auth/invalid-credential": "Email or password is incorrect.",
    "auth/email-already-in-use": "An account already exists for this email.",
    "auth/operation-not-allowed": "This sign-in method is not enabled in Firebase Console.",
    "auth/network-request-failed": "Network request failed. Check your internet connection.",
    "auth/popup-closed-by-user": "Google sign-in was cancelled.",
    "auth/unauthorized-domain": "This website domain is not authorized in Firebase Authentication settings.",
  };
  return messages[authError.code] || authError.message;
}
function Auth({ signup = false }) {
  const [role, setRole] = useState("management");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const googleAuth = async () => {
    setError("");
    setBusy(true);
    try {
      const result = await withTimeout(signInWithPopup(auth, new GoogleAuthProvider()));
      await withTimeout(saveUserProfile(result.user, role));
      localStorage.setItem("sih_role", role);
      window.location.href = "/dashboard";
    } catch (authError) {
      setError(readableAuthError(authError));
    } finally {
      setBusy(false);
    }
  };
  const submit = async (e) => {
    e.preventDefault();
    setError("");
    setBusy(true);
    const form = new FormData(e.currentTarget);
    try {
      const email = form.get("email");
      const password = form.get("password");
      const displayName = form.get("displayName");
      const employeeId = form.get("employeeId");
      const phone = form.get("phone");
      const subsidiary = form.get("subsidiary");
      const mineId = form.get("mineId");
      const result = signup
        ? await withTimeout(createUserWithEmailAndPassword(auth, email, password))
        : await withTimeout(signInWithEmailAndPassword(auth, email, password));
      if (signup)
        try {
          await withTimeout(
            saveUserProfile(result.user, role, {
              displayName,
              employeeId,
              phone,
              subsidiary,
              mineId: role === "inspector" ? mineId : null,
              createdAt: serverTimestamp(),
            }),
          );
        } catch {
          localStorage.setItem(
            "sih_pending_profile",
            JSON.stringify({
              uid: result.user.uid,
              email,
              displayName,
              employeeId,
              phone,
              subsidiary,
              role,
              mineId: role === "inspector" ? mineId : null,
            }),
          );
        }
      localStorage.setItem("sih_role", signup ? role : "management");
      window.location.href = "/dashboard";
    } catch (authError) {
      setError(readableAuthError(authError));
    } finally {
      setBusy(false);
    }
  };
  return (
    <main className="auth-page">
      <div className="auth-aside">
        <div className="brand-mark">
          <Mountain size={22} /> SIH / 26
        </div>
        <div className="auth-copy">
          <p className="eyebrow">National coal governance grid</p>
          <h1>
            Clarity at
            <br />
            <em>every seam.</em>
          </h1>
          <p>
            One operating picture for safer mines, cleaner production, and
            accountable compliance.
          </p>
        </div>
        <div className="auth-footer">
          SYSTEM ONLINE <span>•</span> 04 SEP 2026
        </div>
      </div>
      <form className="auth-form" onSubmit={submit}>
        <div className="mobile-brand">
          <Mountain size={22} /> SIH / 26
        </div>
        <p className="eyebrow">
          {signup ? "Create workspace access" : "Secure operations console"}
        </p>
        <h2>{signup ? "Request access" : "Welcome back"}</h2>
        <p className="muted">
          {signup
            ? "Set up your role for the governance grid."
            : "Sign in to resume your compliance watch."}
        </p>
        {signup && (
          <>
            <label>
              Full name
              <input name="displayName" type="text" required placeholder="Arjun Kumar" />
            </label>
            <div className="auth-form-row">
              <label>
                Employee ID
                <input name="employeeId" type="text" required placeholder="CI-20481" />
              </label>
              <label>
                Phone number
                <input name="phone" type="tel" required placeholder="+91 98765 43210" />
              </label>
            </div>
            <label>
              Subsidiary / organization
              <select name="subsidiary" defaultValue="SECL">
                <option value="CIL Corporate">Coal India Limited</option>
                <option value="SECL">South Eastern Coalfields (SECL)</option>
                <option value="MCL">Mahanadi Coalfields (MCL)</option>
                <option value="CCL">Central Coalfields (CCL)</option>
                <option value="NCL">Northern Coalfields (NCL)</option>
                <option value="DGMS">DGMS / Regulatory Authority</option>
              </select>
            </label>
          </>
        )}
        <label>
          Work email
          <input
            name="email"
            type="email"
            required
            placeholder="name@coalindia.in"
          />
        </label>
        <label>
          Password
          <input
            name="password"
            type="password"
            required
            minLength="6"
            placeholder="••••••••••••"
          />
        </label>
        {signup && (
          <>
            <label>
              Access role
              <select name="role" value={role} onChange={(e) => setRole(e.target.value)}>
                <option value="management">Corporate Management</option>
                <option value="inspector">Mine Safety Officer</option>
                <option value="regulator">Regulatory Authority</option>
              </select>
            </label>
            {role === "inspector" && (
              <label>
                Assigned mine site
                <select name="mineId" required defaultValue="m1">
                  <option value="m1">Gevra OC · SECL</option>
                  <option value="m2">Bokaro &amp; Kargali · CCL</option>
                  <option value="m3">NCL Jayant · NCL</option>
                  <option value="m4">Talcher Central · MCL</option>
                </select>
              </label>
            )}
          </>
        )}
        {error && <p className="auth-error">{error}</p>}
        <button className="primary-button" type="submit" disabled={busy}>
          {busy
            ? "Connecting..."
            : signup
              ? "Create secure access"
              : "Enter command center"}{" "}
          <ChevronDown size={16} className="rotate" />
        </button>
        <div className="auth-divider"><span>or continue with</span></div>
        <button className="google-button" type="button" onClick={googleAuth} disabled={busy}>
          <span className="google-mark">G</span> Continue with Google
        </button>
        <p className="auth-switch">
          {signup ? "Already have access?" : "New to the grid?"}{" "}
          <a href={signup ? "/login" : "/signup"}>
            {signup ? "Sign in" : "Request an account"}
          </a>
        </p>
      </form>
    </main>
  );
}
function Console({ user, profile }) {
  const [open, setOpen] = useState(false);
  const [notice, setNotice] = useState(false);
  const accountName = profile?.displayName || user?.displayName || user?.email?.split("@")[0] || "User";
  const accountRole = profile?.role || "management";
  const roleLabels = { inspector: "Mine Safety Officer", management: "Corporate Management", regulator: "Regulatory Authority" };
  const initials = accountName.split(" ").map((part) => part[0]).join("").slice(0, 2).toUpperCase();
  const organization = profile?.subsidiary || "Coal India Limited";
  const [liveInspections, setLiveInspections] = useState([]);
  useEffect(() => {
    const inspectionsQuery = query(collection(db, "inspections"), orderBy("createdAt", "desc"));
    return onSnapshot(inspectionsQuery, (snapshot) => {
      setLiveInspections(snapshot.docs.map((item) => ({ id: item.id, ...item.data() })));
    }, () => setLiveInspections([]));
  }, []);
  return (
    <div className="app-shell">
      <aside className={open ? "sidebar open" : "sidebar"}>
        <div className="brand-mark">
          <Mountain size={22} /> SIH / 26
        </div>
        <div className="workspace">
          <div className="workspace-icon">
            <Building2 size={17} />
          </div>
          <div>
            <strong>{organization}</strong>
            <span>{profile?.mineId ? `Assigned site · ${profile.mineId}` : "National operations"}</span>
          </div>
          <ChevronDown size={15} />
        </div>
        <nav>
          <NavItem
            to="/dashboard"
            icon={<LayoutDashboard size={18} />}
            label="Command center"
          />
          <NavItem
            to="/map"
            icon={<MapIcon size={18} />}
            label="Mine intelligence"
          />
          <NavItem
            to="/compliance"
            icon={<ClipboardCheck size={18} />}
            label="Compliance watch"
          />
          <NavItem
            to="/operations"
            icon={<Activity size={18} />}
            label="Operations & field"
          />
          <NavItem
            to="/contractors"
            icon={<HardHat size={18} />}
            label="Contractor governance"
          />
          <NavItem
            to="/digitize"
            icon={<FileScan size={18} />}
            label="Form digitizer"
          />
          <NavItem
            to="/analytics"
            icon={<BrainCircuit size={18} />}
            label="AI risk hub"
          />
          <NavItem
            to="/grievances"
            icon={<MessageSquareWarning size={18} />}
            label="Grievances"
          />
        </nav>
        <div className="sidebar-bottom">
          <div className="system-status">
            <span className="live-dot" /> All systems operational
          </div>
          <button
            className="profile"
            onClick={async () => {
              await signOut(auth);
              localStorage.removeItem("sih_role");
              window.location.href = "/login";
            }}
          >
            <span className="avatar">{initials}</span>
            <span>
              <strong>{accountName}</strong>
              <small>{roleLabels[accountRole] || accountRole}</small>
            </span>
            <ChevronDown size={15} />
          </button>
        </div>
      </aside>
      <div className="main-area">
        <header>
          <button
            className="icon-button mobile-menu"
            onClick={() => setOpen(!open)}
          >
            {open ? <X /> : <Menu />}
          </button>
          <div className="crumb">
            <span>Coal India Limited</span>
            <b>/</b>
            <strong>{useLocation().pathname.slice(1) || "dashboard"}</strong>
          </div>
          <div className="header-actions">
            <div className="search-box">
              <Search size={16} />
              <input placeholder="Search mines, rules, logs..." />
            </div>
            <button className="icon-button" onClick={() => setNotice(!notice)}>
              <Bell size={18} />
              <i />
            </button>
            <div className="mini-avatar">{initials}</div>
          </div>
        </header>
        {notice && (
          <div className="notification">
            <strong>3 items need attention</strong>
            <span>Gevra OC has an overdue closure plan.</span>
          </div>
        )}
        <div className="content">
          <Routes>
            <Route path="/" element={<Navigate to="/dashboard" replace />} />
            <Route path="/dashboard" element={<Dashboard liveInspections={liveInspections} />} />
            <Route path="/map" element={<MapView />} />
            <Route path="/compliance" element={<Compliance liveInspections={liveInspections} />} />
            <Route path="/operations" element={<Operations />} />
            <Route path="/contractors" element={<Contractors />} />
            <Route path="/digitize" element={<Digitize />} />
            <Route path="/analytics" element={<Analytics />} />
            <Route path="/grievances" element={<Grievances />} />
          </Routes>
        </div>
      </div>
    </div>
  );
}
function NavItem({ to, icon, label }) {
  return (
    <NavLink
      to={to}
      onClick={() =>
        document.querySelector(".sidebar")?.classList.remove("open")
      }
      className="nav-item"
    >
      {icon}
      <span>{label}</span>
    </NavLink>
  );
}
function Heading({ eyebrow, title, copy, action }) {
  return (
    <div className="page-heading">
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        <p className="muted">{copy}</p>
      </div>
      {action}
    </div>
  );
}
function PanelHead({ title, meta }) {
  return (
    <div className="panel-head">
      <h2>{title}</h2>
      <span>{meta}</span>
    </div>
  );
}
function Kpi({ icon, label, value, delta, sub, tone }) {
  return (
    <div className="kpi">
      <div className={`kpi-icon ${tone}`}>{icon}</div>
      <p>{label}</p>
      <strong>{value}</strong>
      <div>
        <span className={tone === "red" ? "negative" : "positive"}>
          {delta}
        </span>{" "}
        <small>{sub}</small>
      </div>
    </div>
  );
}
function Dashboard({ liveInspections = [] }) {
  const liveViolations = liveInspections.filter((item) => item.status === "violation").length;
  return (
    <>
      <Heading
        eyebrow="Friday, 04 September 2026"
        title="Command center"
        copy="A live view of safety, statutory health, and production across the grid."
        action={
          <button className="outline-button">
            <UploadCloud size={16} /> Export briefing
          </button>
        }
      />
      <div className="kpi-grid">
        <Kpi
          icon={<CircleAlert />}
          label="Active violations"
          value={liveInspections.length ? liveViolations : "16"}
          delta="↓ 12.4%"
          sub="vs. last month"
          tone="red"
        />
        <Kpi
          icon={<Bell />}
          label="Pending escalations"
          value="07"
          delta="3 critical"
          sub="require attention"
          tone="amber"
        />
        <Kpi
          icon={<ShieldCheck />}
          label="Safety index"
          value="87.4"
          delta="↑ 4.8%"
          sub="out of 100"
          tone="green"
        />
        <Kpi
          icon={<Mountain />}
          label="High-risk mines"
          value="02"
          delta="of 18 monitored"
          sub="risk score > 70"
          tone="blue"
        />
      </div>
      <div className="dashboard-grid">
        <section className="panel chart-panel">
          <PanelHead title="Statutory health" meta="Last 6 months" />
          <div className="legend">
            <span>
              <i className="green-dot" /> Compliance rate
            </span>
            <span>
              <i className="blue-dot" /> Violations resolved
            </span>
          </div>
          <ResponsiveContainer width="100%" height={260}>
            <BarChart data={trend} barGap={8}>
              <CartesianGrid vertical={false} stroke="#e5e8e5" />
              <XAxis dataKey="month" axisLine={false} tickLine={false} />
              <YAxis axisLine={false} tickLine={false} />
              <Tooltip />
              <Bar dataKey="compliant" fill="#3f9b82" radius={[3, 3, 0, 0]} />
              <Bar dataKey="resolved" fill="#2c5667" radius={[3, 3, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </section>
        <section className="panel risk-panel">
          <PanelHead title="Risk distribution" meta="18 active mines" />
          <ResponsiveContainer width="100%" height={175}>
            <PieChart>
              <Pie
                data={[{ value: 10 }, { value: 6 }, { value: 2 }]}
                innerRadius={57}
                outerRadius={78}
                paddingAngle={4}
                dataKey="value"
              >
                {["#3f9b82", "#e4a853", "#ef6461"].map((color, i) => (
                  <Cell key={i} fill={color} />
                ))}
              </Pie>
            </PieChart>
          </ResponsiveContainer>
          <div className="risk-list">
            <span>
              <i className="green-dot" /> Low risk <b>10</b>
            </span>
            <span>
              <i className="amber-dot" /> Elevated <b>06</b>
            </span>
            <span>
              <i className="red-dot" /> High risk <b>02</b>
            </span>
          </div>
        </section>
      </div>
      <section className="panel live-feed-panel">
        <PanelHead title="Live inspector feed" meta={liveInspections.length ? `${liveInspections.length} mobile reports` : "Waiting for mobile reports"} />
        {liveInspections.length === 0 ? <p className="muted">Inspection reports submitted from the Flutter app will appear here automatically after Firebase sync.</p> : <div className="live-feed">{liveInspections.slice(0, 4).map((item) => <div className="live-feed-row" key={item.id}><span className={`feed-dot ${item.status === "violation" ? "red" : "green"}`} /><div><strong>{item.title || "Inspection report"}</strong><small>{item.mineCode || item.mineId || "Mine site"} · {item.category || "safety"} · {item.inspectorId || "Inspector"}</small></div><span className={`status ${item.status === "violation" ? "high-risk" : "compliant"}`}>{item.status || "pending"}</span></div>)}</div>}
      </section>
      <section className="panel">
        <PanelHead title="Mine watchlist" meta="View all mines →" />
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Mine site</th>
                <th>Subsidiary</th>
                <th>Safety index</th>
                <th>Open issues</th>
                <th>Production MTD</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {mines.map((m) => (
                <tr key={m.id}>
                  <td>
                    <strong>{m.name}</strong>
                    <small>Updated 18 min ago</small>
                  </td>
                  <td>{m.subsidiary}</td>
                  <td>
                    <div className="score">
                      <span
                        style={{ width: `${m.risk}%`, background: m.color }}
                      />
                      <b>{m.risk}/100</b>
                    </div>
                  </td>
                  <td>
                    <span className={m.open > 5 ? "issue critical" : "issue"}>
                      {m.open} open
                    </span>
                  </td>
                  <td>{m.production}</td>
                  <td>
                    <span
                      className={`status ${m.status.toLowerCase().replace(" ", "-")}`}
                    >
                      {m.status}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}
function MapView() {
  return (
    <>
      <Heading
        eyebrow="Spatial intelligence"
        title="Mine intelligence"
        copy="Satellite risk assessment with explainable zone-level signals."
        action={
          <button className="outline-button">
            <MapIcon size={16} /> Recenter grid
          </button>
        }
      />
      <div className="map-layout">
        <section className="panel map-card">
          <MineRiskHeatmap />
        </section>
        <section className="panel site-list">
          <PanelHead title="Priority sites" meta="4 shown" />
          {mines.map((m) => (
            <div className="site-row" key={m.id}>
              <span className="site-pin" style={{ background: m.color }}>
                <Mountain size={15} />
              </span>
              <div>
                <strong>{m.name}</strong>
                <small>
                  {m.subsidiary} · {m.open} open issues
                </small>
              </div>
              <b style={{ color: m.color }}>{m.risk}</b>
            </div>
          ))}
        </section>
      </div>
    </>
  );
}
function Compliance({ liveInspections = [] }) {
  const [filter, setFilter] = useState("All");
  const rows = compliance.filter((r) => filter === "All" || r[0] === filter);
  return (
    <>
      <Heading
        eyebrow="Statutory controls"
        title="Compliance watch"
        copy="Every obligation, owner, deadline, and escalation in one register."
        action={
          <button className="primary-button compact">
            <ClipboardCheck size={16} /> Log inspection
          </button>
        }
      />
      <div className="filter-bar">
        <div className="tabs">
          {["All", "DGMS", "MoEFCC", "Labour"].map((x) => (
            <button
              className={filter === x ? "active" : ""}
              onClick={() => setFilter(x)}
              key={x}
            >
              {x}
            </button>
          ))}
        </div>
        <div className="filter-search">
          <Search size={15} /> Filter requirements
        </div>
      </div>
      {liveInspections.length > 0 && (
        <section className="panel mobile-issues-panel">
          <PanelHead title="Mobile inspection issues" meta="Live from inspector app" />
          {liveInspections.filter((item) => item.status === "violation").slice(0, 3).map((item) => (
            <div className="mobile-issue-row" key={item.id}>
              <CircleAlert size={16} />
              <div><strong>{item.title || "Field violation reported"}</strong><small>{item.mineCode || item.mineId} · {item.inspectorId} · {item.severity || "review required"}</small></div>
              <span className="risk-badge critical">Needs action</span>
            </div>
          ))}
        </section>
      )}
      <section className="panel">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Authority</th>
                <th>Requirement</th>
                <th>Rule code</th>
                <th>Mine site</th>
                <th>Deadline</th>
                <th>Risk</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r[2]}>
                  <td>
                    <span className="authority">{r[0]}</span>
                  </td>
                  <td>
                    <strong>{r[1]}</strong>
                  </td>
                  <td className="mono">{r[2]}</td>
                  <td>{r[3]}</td>
                  <td>
                    <span
                      className={
                        r[4].includes("Overdue") || r[4].includes("today")
                          ? "deadline overdue"
                          : "deadline"
                      }
                    >
                      {r[4]}
                    </span>
                  </td>
                  <td>
                    <span className={`risk-badge ${r[5].toLowerCase()}`}>
                      {r[5]}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}
function Operations() {
  const [logged, setLogged] = useState(false);
  return (
    <>
      <Heading
        eyebrow="Field governance"
        title="Operations & field"
        copy="A time-stamped operational pulse from officers, supervisors, and mine sites."
        action={
          <button
            className="primary-button compact"
            onClick={() => setLogged(true)}
          >
            <Activity size={16} /> Log field activity
          </button>
        }
      />
      {logged && (
        <div className="success-banner">
          <ShieldCheck size={16} /> Field activity saved to the local review
          queue. Firebase sync will activate when keys are added.
        </div>
      )}
      <div className="ops-grid">
        <section className="panel field-card">
          <PanelHead title="Field pulse" meta="Live · 18 officers online" />
          <div className="field-kpis">
            <div>
              <strong>142</strong>
              <span>Reports this week</span>
            </div>
            <div>
              <strong>96%</strong>
              <span>Geo-tagged</span>
            </div>
            <div>
              <strong>18 min</strong>
              <span>Avg. sync delay</span>
            </div>
          </div>
          <div className="field-form">
            <label>
              Activity type
              <select>
                <option>Safety observation</option>
                <option>Environmental reading</option>
                <option>Worker attendance</option>
                <option>Incident report</option>
              </select>
            </label>
            <label>
              Mine site
              <select>
                <option>Gevra OC · SECL</option>
                <option>Talcher Central · MCL</option>
              </select>
            </label>
            <div className="coordinate">
              <MapIcon size={17} />
              <span>
                <strong>22.35° N, 82.61° E</strong>
                <small>GPS captured · 04 Sep 2026, 10:42 IST</small>
              </span>
              <span className="gps-pill">Verified</span>
            </div>
            <label>
              Observation notes
              <textarea placeholder="Describe the observation or field activity..." />
            </label>
            <button className="outline-button">
              <UploadCloud size={15} /> Attach photo / evidence
            </button>
          </div>
        </section>
        <section className="panel activity-card">
          <PanelHead title="Recent field activity" meta="All sites" />
          {fieldActivity.map((item) => (
            <div className="activity-row" key={item.person}>
              <span className={`activity-icon ${item.tone}`}>
                <Activity size={15} />
              </span>
              <div>
                <strong>{item.action}</strong>
                <small>
                  {item.person} · {item.role}
                </small>
                <small>
                  {item.mine} · {item.time}
                </small>
              </div>
            </div>
          ))}
        </section>
      </div>
    </>
  );
}
function Contractors() {
  return (
    <>
      <Heading
        eyebrow="People & contracts"
        title="Contractor governance"
        copy="Track workforce readiness, induction coverage, and contract risk across every site."
        action={
          <button className="primary-button compact">
            <Users size={16} /> Add contractor
          </button>
        }
      />
      <div className="kpi-grid">
        <Kpi
          icon={<HardHat />}
          label="Active contractors"
          value="38"
          delta="1,482"
          sub="workers on site"
          tone="blue"
        />
        <Kpi
          icon={<ShieldCheck />}
          label="Training coverage"
          value="93.6%"
          delta="↑ 2.1%"
          sub="this quarter"
          tone="green"
        />
        <Kpi
          icon={<CircleAlert />}
          label="Documents expiring"
          value="09"
          delta="3 this week"
          sub="renewal required"
          tone="amber"
        />
        <Kpi
          icon={<FileText />}
          label="Open grievances"
          value="06"
          delta="↓ 18%"
          sub="vs. last month"
          tone="red"
        />
      </div>
      <section className="panel">
        <PanelHead title="Contractor register" meta="Synced 12 min ago" />
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Contractor</th>
                <th>Mine site</th>
                <th>Workers</th>
                <th>Induction coverage</th>
                <th>Governance status</th>
              </tr>
            </thead>
            <tbody>
              {contractors.map((c) => (
                <tr key={c.name}>
                  <td>
                    <strong>{c.name}</strong>
                    <small>Contract ID · CI-{c.workers}84</small>
                  </td>
                  <td>{c.mine}</td>
                  <td>{c.workers}</td>
                  <td>
                    <div className="score">
                      <span
                        style={{
                          width: `${c.training}%`,
                          background: c.training > 95 ? "#3f9b82" : "#e4a853",
                        }}
                      />
                      <b>{c.training}% trained</b>
                    </div>
                  </td>
                  <td>
                    <span
                      className={
                        c.status === "Compliant"
                          ? "status compliant"
                          : "status elevated"
                      }
                    >
                      {c.status}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}
function Grievances() {
  const [filter, setFilter] = useState("All");
  const rows = grievances.filter(
    (g) => filter === "All" || g.status === filter,
  );
  return (
    <>
      <Heading
        eyebrow="Accountability desk"
        title="Grievances & actions"
        copy="Make worker and community concerns visible, owned, and resolved on time."
        action={
          <button className="primary-button compact">
            <MessageSquareWarning size={16} /> Register grievance
          </button>
        }
      />
      <div className="filter-bar">
        <div className="tabs">
          {["All", "Open", "Investigating", "Resolved"].map((x) => (
            <button
              className={filter === x ? "active" : ""}
              onClick={() => setFilter(x)}
              key={x}
            >
              {x}
            </button>
          ))}
        </div>
        <div className="filter-search">
          <Search size={15} /> Search grievances
        </div>
      </div>
      <section className="panel">
        <PanelHead title="Grievance register" meta="SLA target · 7 days" />
        {rows.map((g) => (
          <div className="grievance-row" key={g.title}>
            <span className="grievance-icon">
              <MessageSquareWarning size={17} />
            </span>
            <div className="grievance-copy">
              <strong>{g.title}</strong>
              <small>
                {g.mine} · Raised {g.age} ago
              </small>
            </div>
            <span
              className={`status ${g.status === "Resolved" ? "compliant" : g.status === "Open" ? "high-risk" : "elevated"}`}
            >
              {g.status}
            </span>
            <div className="owner">
              <small>Owner</small>
              <strong>{g.owner}</strong>
            </div>
            <ChevronDown size={15} />
          </div>
        ))}
      </section>
    </>
  );
}
function Digitize() {
  const [file, setFile] = useState(null);
  const [done, setDone] = useState(false);
  return (
    <>
      <Heading
        eyebrow="Document intelligence"
        title="Form digitizer"
        copy="Turn statutory paperwork into structured, reviewable records."
      />
      <div className="digitize-grid">
        <section className="panel upload-panel">
          <div
            className="upload-zone"
            onClick={() => document.getElementById("file-upload").click()}
          >
            <input
              id="file-upload"
              type="file"
              hidden
              onChange={(e) => setFile(e.target.files[0])}
            />
            <div className="upload-icon">
              <FileScan size={25} />
            </div>
            <h2>{file ? file.name : "Drop a statutory form here"}</h2>
            <p>PDF, JPG, or PNG up to 25 MB</p>
            <button className="outline-button">Browse files</button>
          </div>
          <div className="processing-row">
            <span className={done ? "live-dot" : "amber-dot"} />{" "}
            {done ? "Extraction complete" : "OCR service ready"}
            <small>FastAPI · Tesseract</small>
          </div>
        </section>
        <section className="panel review-panel">
          <PanelHead title="Review extracted data" meta="Draft record" />
          <label>
            Document type
            <select>
              <option>Shift in-charge report</option>
              <option>Air quality reading</option>
            </select>
          </label>
          <label>
            Mine site
            <select>
              <option>Gevra OC · SECL</option>
              <option>Talcher Central · MCL</option>
            </select>
          </label>
          <div className="form-row">
            <label>
              Shift date
              <input type="date" defaultValue="2026-09-04" />
            </label>
            <label>
              PM10 reading
              <input defaultValue={file ? "118 µg/m3" : "Awaiting OCR"} />
            </label>
          </div>
          <label>
            Extracted observations
            <textarea
              defaultValue={
                file
                  ? "Dust suppression system inspected. Haul road section 4 requires additional water coverage."
                  : "Upload a form to populate extracted observations."
              }
            />
          </label>
          <button className="primary-button" onClick={() => setDone(true)}>
            Save to Firestore <ShieldCheck size={16} />
          </button>
        </section>
      </div>
    </>
  );
}
function Analytics() {
  return (
    <>
      <Heading
        eyebrow="Machine intelligence"
        title="AI risk hub"
        copy="Surface recurring failure patterns before they become incidents."
        action={
          <button className="primary-button compact">
            <BrainCircuit size={16} /> Run risk scan
          </button>
        }
      />
      <div className="analytics-grid">
        <section className="panel anomaly">
          <PanelHead title="Recurring anomaly patterns" meta="Last 90 days" />
          {[
            [
              "Haul road dust suppression",
              "7 repeat observations across 3 mines",
              78,
              "red",
            ],
            [
              "Roof bolting lapses",
              "4 repeat observations across 2 mines",
              52,
              "amber",
            ],
            [
              "Contractor induction gaps",
              "3 repeat observations across 4 mines",
              34,
              "blue",
            ],
          ].map(([name, copy, value, tone]) => (
            <div className="pattern" key={name}>
              <div className={`pattern-icon ${tone}`}>
                <CircleAlert size={18} />
              </div>
              <div>
                <strong>{name}</strong>
                <p>{copy}</p>
                <div className={`pattern-bar ${tone}`}>
                  <span style={{ width: `${value}%` }} />
                </div>
              </div>
              <b>{value}%</b>
            </div>
          ))}
        </section>
        <section className="panel score-panel">
          <PanelHead title="Model output" meta="v0.8.2 · live" />
          <div className="model-score">
            <strong>64</strong>
            <span>/100</span>
            <small>Network risk index</small>
          </div>
          <div className="score-scale">
            <span>Low</span>
            <i />
            <span>High</span>
          </div>
          <p className="muted">
            The current signal is elevated by unresolved safety observations at
            Gevra OC and Talcher Central.
          </p>
          <button className="outline-button full">
            View methodology <BarChart3 size={16} />
          </button>
        </section>
      </div>
    </>
  );
}
export default App;
