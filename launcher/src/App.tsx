import { SetupWizard } from "@/features/SetupWizard";

/** Phase 2 shell: titlebar drag region (traffic lights sit at 18,22) and the engine setup wizard.
 *  Phase 3 replaces the body with the rail, hero, grid, bottle manager and console. */
export default function App() {
  return (
    <div className="flex h-full flex-col bg-canvas/95">
      <div data-tauri-drag-region className="titlebar-drag h-titlebar shrink-0" />
      <main className="min-h-0 flex-1 overflow-y-auto pb-10">
        <SetupWizard />
      </main>
    </div>
  );
}
