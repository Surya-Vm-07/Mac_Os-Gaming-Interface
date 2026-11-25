import { useCallback, useEffect, useMemo, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { open } from "@tauri-apps/plugin-dialog";
import { Check, Cpu, Download, FolderOpen, Layers, Loader2, RefreshCw, ShieldCheck, Wine, X } from "lucide-react";

import { api, errorMessage, formatBytes } from "@/lib/ipc";
import { easeOutExpo, spring } from "@/lib/motion";
import type { DownloadProgress, Runtime, SystemReport } from "@/lib/types";

type StepState = "done" | "todo" | "busy" | "optional";

/** First-launch engine setup: Rosetta → free Wine runtime → graphics stacks. Terminal-free. */
export function SetupWizard({ onReady }: { onReady?: (report: SystemReport) => void }) {
  const [report, setReport] = useState<SystemReport | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [progress, setProgress] = useState<DownloadProgress | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const next = await api.systemReport();
      setReport(next);
      if (next.ready) onReady?.(next);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [onReady]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const base: Runtime | undefined = useMemo(() => report?.runtimes.find((r) => r.flavor === "base"), [report]);

  async function run(key: string, task: () => Promise<unknown>) {
    setBusy(key);
    setError(null);
    setProgress(null);
    try {
      await task();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(null);
      setProgress(null);
      await refresh();
    }
  }

  async function importGptk(candidate?: string) {
    if (!base) return;
    const path =
      candidate ??
      (await open({ directory: true, title: "Select your Game Porting Toolkit folder or mounted volume" }));
    if (typeof path !== "string") return;
    await run("d3dmetal", () => api.importGptk(base.id, path));
  }

  if (!report) {
    return (
      <div className="grid h-full place-items-center text-ink-muted">
        <Loader2 className="size-6 animate-spin" />
      </div>
    );
  }

  const steps: {
    key: string;
    icon: React.ReactNode;
    title: string;
    detail: string;
    state: StepState;
    action?: { label: string; run: () => void };
  }[] = [
    {
      key: "rosetta",
      icon: <ShieldCheck className="size-5" />,
      title: "Rosetta 2",
      detail: "Windows games are x86_64. Rosetta translates them for Apple Silicon. Required.",
      state: busy === "rosetta" ? "busy" : report.rosettaInstalled ? "done" : "todo",
      ...(!report.rosettaInstalled ? { action: { label: "Install", run: () => void run("rosetta", api.installRosetta) } } : {}),
    },
    {
      key: "wine",
      icon: <Wine className="size-5" />,
      title: "Wine Staging runtime",
      detail: base ? `${base.name} ${base.version}` : "Free Gcenx macOS build, downloaded from GitHub (~200 MB). Required.",
      state: busy === "wine" ? "busy" : report.hasBaseRuntime ? "done" : "todo",
      ...(!report.hasBaseRuntime ? { action: { label: "Download", run: () => void run("wine", () => api.installWine(setProgress)) } } : {}),
    },
    {
      key: "d3dmetal",
      icon: <Cpu className="size-5" />,
      title: "D3DMetal (Apple GPTK)",
      detail: report.d3dmetalReady
        ? "Imported. DX11/DX12 AAA path ready."
        : "Import from your free Game Porting Toolkit download (developer.apple.com/games). Apple doesn't allow redistributing it.",
      state: busy === "d3dmetal" ? "busy" : report.d3dmetalReady ? "done" : "optional",
      ...(base && !report.d3dmetalReady
        ? { action: { label: report.gptkCandidates[0] ? "Import detected" : "Choose folder…", run: () => void importGptk(report.gptkCandidates[0]) } }
        : {}),
    },
    {
      key: "dxmt",
      icon: <Layers className="size-5" />,
      title: "DXMT",
      detail: "Open-source D3D10/11 → Metal. Often the fastest DX11 path.",
      state: busy === "dxmt" ? "busy" : report.dxmtReady ? "done" : "optional",
      ...(base && !report.dxmtReady ? { action: { label: "Download", run: () => void run("dxmt", () => api.installDxmt(base.id, setProgress)) } } : {}),
    },
    {
      key: "dxvk",
      icon: <Layers className="size-5" />,
      title: "DXVK (macOS)",
      detail: "D3D9–11 → Vulkan → Metal. Best for older DX9 titles.",
      state: busy === "dxvk" ? "busy" : report.dxvkReady ? "done" : "optional",
      ...(!report.dxvkReady ? { action: { label: "Download", run: () => void run("dxvk", () => api.installDxvk(setProgress)) } } : {}),
    },
  ];

  return (
    <motion.div
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={easeOutExpo}
      className="mx-auto flex h-full max-w-3xl flex-col justify-center gap-8 px-8"
    >
      <header className="space-y-3">
        <p className="font-mono text-micro tracking-[0.3em] text-neon">AETHER LAUNCHER · ENGINE SETUP</p>
        <h1 className="text-hero font-black">Play Windows games for $0.</h1>
        <p className="text-ink-muted">
          {report.appleSilicon ? "Apple Silicon" : report.arch} · macOS {report.macosVersion ?? "unknown"}. No CrossOver, no
          Parallels, no Homebrew.
        </p>
      </header>

      <ol className="space-y-2">
        {steps.map((step, index) => (
          <motion.li
            key={step.key}
            initial={{ opacity: 0, x: -8 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ ...spring, delay: index * 0.04 }}
            className="flex items-center gap-4 rounded-card border border-line bg-carbon px-5 py-4"
          >
            <span className={step.state === "done" ? "text-ok" : "text-neon"}>{step.icon}</span>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <span className="font-semibold">{step.title}</span>
                {step.state === "optional" && <span className="font-mono text-micro text-ink-faint">OPTIONAL</span>}
              </div>
              <p className="truncate text-sm text-ink-muted">{step.detail}</p>
            </div>
            <StepControl state={step.state} {...(step.action ? { action: step.action } : {})} disabled={busy !== null} />
          </motion.li>
        ))}
      </ol>

      <AnimatePresence>
        {progress && <ProgressBar progress={progress} />}
        {error && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="flex items-start gap-3 rounded-card border border-danger/40 bg-danger/10 px-4 py-3 font-mono text-sm text-danger"
          >
            <X className="mt-0.5 size-4 shrink-0" />
            <span className="whitespace-pre-wrap">{error}</span>
          </motion.div>
        )}
      </AnimatePresence>

      <footer className="flex items-center justify-between">
        <button onClick={() => void refresh()} className="flex items-center gap-2 text-sm text-ink-muted hover:text-ink">
          <RefreshCw className="size-4" /> Re-check
        </button>
        <span className={`font-mono text-micro ${report.ready ? "text-ok" : "text-ink-faint"}`}>
          {report.ready ? "READY TO PLAY" : "ROSETTA + WINE REQUIRED"}
        </span>
      </footer>
    </motion.div>
  );
}

function StepControl({ state, action, disabled }: { state: StepState; action?: { label: string; run: () => void }; disabled: boolean }) {
  if (state === "done") return <Check className="size-5 text-ok" />;
  if (state === "busy") return <Loader2 className="size-5 animate-spin text-neon" />;
  if (!action) return null;
  return (
    <motion.button
      whileHover={{ scale: 1.04 }}
      whileTap={{ scale: 0.97 }}
      transition={spring}
      disabled={disabled}
      onClick={action.run}
      className="flex items-center gap-2 rounded-pill bg-neon px-4 py-1.5 text-sm font-bold text-canvas shadow-neon disabled:opacity-40"
    >
      {action.label.startsWith("Choose") ? <FolderOpen className="size-4" /> : <Download className="size-4" />}
      {action.label}
    </motion.button>
  );
}

function ProgressBar({ progress }: { progress: DownloadProgress }) {
  const fraction =
    progress.phase === "downloading" && progress.total ? progress.received / progress.total : progress.phase === "done" ? 1 : null;
  const label =
    progress.phase === "downloading"
      ? `Downloading ${formatBytes(progress.received)}${progress.total ? ` / ${formatBytes(progress.total)}` : ""}`
      : { resolving: "Finding latest release…", extracting: "Extracting…", installing: "Installing…", done: "Done" }[progress.phase];
  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="space-y-2">
      <div className="h-1.5 overflow-hidden rounded-pill bg-line">
        <motion.div
          className="h-full rounded-pill bg-gradient-to-r from-neon-deep to-neon"
          animate={{ width: fraction === null ? ["0%", "100%"] : `${Math.round(fraction * 100)}%` }}
          transition={fraction === null ? { duration: 1.2, repeat: Infinity } : spring}
        />
      </div>
      <p className="font-mono text-micro text-ink-muted">{label}</p>
    </motion.div>
  );
}
