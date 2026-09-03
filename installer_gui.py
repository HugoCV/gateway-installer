#!/usr/bin/env python3
from __future__ import annotations

import os
import platform
import queue
import getpass
import shutil
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk


ROOT_DIR = Path(__file__).resolve().parent
DEFAULT_REPO_URL = "https://github.com/HugoCV/gateway.git"
DEFAULT_GATEWAY_REF = "main"
OPERATIONS = ("Instalar", "Reparar", "Actualizar", "Desinstalar")
DEFAULT_ENV_FILE = (
    ROOT_DIR / ".env"
    if (ROOT_DIR / ".env").is_file()
    else Path.home() / "gateway.env"
)


class GatewayInstaller(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Alrotek Gateway Installer")
        self.geometry("900x720")
        self.minsize(780, 620)

        self.process: subprocess.Popen[str] | None = None
        self.launch_after_completion = False
        self.output_queue: queue.Queue[tuple[str, object]] = queue.Queue()

        self.operation = tk.StringVar(value="Instalar")
        self.repo_url = tk.StringVar(value=DEFAULT_REPO_URL)
        self.git_ref = tk.StringVar(value=DEFAULT_GATEWAY_REF)
        self.app_dir = tk.StringVar(value=str(Path.home() / "gateway"))
        self.env_file = tk.StringVar(value=str(DEFAULT_ENV_FILE))
        self.service = tk.BooleanVar(value=True)
        self.autostart = tk.BooleanVar(value=False)
        self.autologin = tk.BooleanVar(value=False)
        self.run_after = tk.BooleanVar(value=False)
        self.reboot_after = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value="Listo")

        self._build_ui()
        self.operation.trace_add("write", lambda *_args: self._sync_operation())
        self.service.trace_add("write", lambda *_args: self._sync_operation())
        self._sync_operation()
        self.after(100, self._drain_output)

    def _build_ui(self) -> None:
        outer = ttk.Frame(self, padding=20)
        outer.pack(fill=tk.BOTH, expand=True)

        ttk.Label(
            outer,
            text="Alrotek Gateway Installer",
            font=("", 20, "bold"),
        ).pack(anchor=tk.W)
        ttk.Label(
            outer,
            text="Instale y mantenga Gateway activo como servicio en segundo plano.",
        ).pack(anchor=tk.W, pady=(4, 16))

        form = ttk.LabelFrame(outer, text="Configuración", padding=16)
        form.pack(fill=tk.X)
        form.columnconfigure(1, weight=1)

        ttk.Label(form, text="Operación").grid(row=0, column=0, sticky=tk.W, pady=5)
        self.operation_box = ttk.Combobox(
            form,
            textvariable=self.operation,
            values=OPERATIONS,
            state="readonly",
            width=20,
        )
        self.operation_box.grid(row=0, column=1, sticky=tk.W, pady=5)

        self._entry_row(form, 1, "Repositorio", self.repo_url)
        self._entry_row(form, 2, "Rama o versión", self.git_ref)
        self._entry_row(
            form,
            3,
            "Directorio del Gateway",
            self.app_dir,
            directory_button=True,
        )
        self._entry_row(
            form,
            4,
            "Archivo de configuración",
            self.env_file,
            file_button=True,
        )

        options = ttk.LabelFrame(outer, text="Opciones", padding=16)
        options.pack(fill=tk.X, pady=(14, 0))

        self.service_check = ttk.Checkbutton(
            options,
            text="Ejecutar Gateway como servicio en segundo plano (recomendado)",
            variable=self.service,
        )
        self.service_check.grid(
            row=0,
            column=0,
            columnspan=2,
            sticky=tk.W,
            pady=(0, 8),
        )

        self.autostart_check = ttk.Checkbutton(
            options,
            text="Iniciar la interfaz Gateway al abrir el escritorio",
            variable=self.autostart,
        )
        self.autostart_check.grid(row=1, column=0, sticky=tk.W, padx=(0, 24))

        self.autologin_check = ttk.Checkbutton(
            options,
            text="Activar autologin de LightDM",
            variable=self.autologin,
        )
        self.autologin_check.grid(row=1, column=1, sticky=tk.W)

        self.run_check = ttk.Checkbutton(
            options,
            text="Ejecutar Gateway al terminar",
            variable=self.run_after,
        )
        self.run_check.grid(row=2, column=0, sticky=tk.W, padx=(0, 24), pady=(8, 0))

        self.reboot_check = ttk.Checkbutton(
            options,
            text="Reiniciar el equipo al terminar",
            variable=self.reboot_after,
        )
        self.reboot_check.grid(row=2, column=1, sticky=tk.W, pady=(8, 0))

        action_bar = ttk.Frame(outer)
        action_bar.pack(fill=tk.X, pady=14)
        self.run_button = ttk.Button(
            action_bar,
            text="Iniciar instalación",
            command=self._start,
        )
        self.run_button.pack(side=tk.LEFT)
        self.progress = ttk.Progressbar(action_bar, mode="indeterminate")
        self.progress.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=14)
        ttk.Button(
            action_bar,
            text="Copiar actividad",
            command=self._copy_log,
        ).pack(side=tk.RIGHT, padx=(8, 0))
        ttk.Label(action_bar, textvariable=self.status).pack(side=tk.RIGHT)

        log_frame = ttk.LabelFrame(outer, text="Actividad", padding=8)
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log = tk.Text(
            log_frame,
            wrap=tk.WORD,
            state=tk.DISABLED,
            background="#171717",
            foreground="#f0f0f0",
            insertbackground="#f0f0f0",
            font=("Courier", 10),
        )
        scrollbar = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log.yview)
        self.log.configure(yscrollcommand=scrollbar.set)
        self.log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

    def _entry_row(
        self,
        parent: ttk.LabelFrame,
        row: int,
        label: str,
        variable: tk.StringVar,
        *,
        directory_button: bool = False,
        file_button: bool = False,
    ) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky=tk.W, pady=5)
        entry = ttk.Entry(parent, textvariable=variable)
        entry.grid(row=row, column=1, sticky=tk.EW, padx=(12, 8), pady=5)

        if directory_button:
            ttk.Button(
                parent,
                text="Seleccionar",
                command=lambda: self._select_directory(variable),
            ).grid(row=row, column=2, pady=5)
        elif file_button:
            ttk.Button(
                parent,
                text="Seleccionar",
                command=lambda: self._select_file(variable),
            ).grid(row=row, column=2, pady=5)

        if label == "Repositorio":
            self.repo_entry = entry
        elif label == "Rama o versión":
            self.ref_entry = entry
        elif label == "Archivo de configuración":
            self.env_entry = entry

    @staticmethod
    def _select_directory(variable: tk.StringVar) -> None:
        selected = filedialog.askdirectory(initialdir=variable.get() or str(Path.home()))
        if selected:
            variable.set(selected)

    @staticmethod
    def _select_file(variable: tk.StringVar) -> None:
        selected = filedialog.askopenfilename(
            initialdir=str(Path(variable.get()).parent),
            title="Seleccione el archivo .env",
            filetypes=(("Archivo de entorno", ".env"), ("Todos los archivos", "*")),
        )
        if selected:
            variable.set(selected)

    def _sync_operation(self) -> None:
        operation = self.operation.get()
        is_install = operation in {"Instalar", "Reparar"}
        is_update = operation == "Actualizar"
        is_uninstall = operation == "Desinstalar"
        uses_service = self.service.get()

        self.repo_entry.configure(state=tk.NORMAL if not is_uninstall else tk.DISABLED)
        self.ref_entry.configure(state=tk.NORMAL if not is_uninstall else tk.DISABLED)
        self.env_entry.configure(state=tk.NORMAL if is_install else tk.DISABLED)
        self.service_check.configure(
            text=(
                "El servicio en segundo plano se eliminará automáticamente"
                if is_uninstall
                else (
                    "El servicio se reiniciará después de actualizar"
                    if is_update
                    else "Ejecutar Gateway como servicio en segundo plano (recomendado)"
                )
            ),
            state=tk.NORMAL if is_install else tk.DISABLED,
        )
        if is_install and uses_service:
            self.autostart.set(False)
        self.run_check.configure(
            state=tk.NORMAL if is_install and not uses_service else tk.DISABLED
        )
        self.autostart_check.configure(
            text=(
                "Eliminar el inicio automático del escritorio"
                if is_uninstall
                else "Iniciar la interfaz Gateway al abrir el escritorio"
            ),
            state=(
                tk.NORMAL
                if is_uninstall or (is_install and not uses_service)
                else tk.DISABLED
            ),
        )
        self.autologin_check.configure(
            text=(
                "Eliminar el autologin configurado por el instalador"
                if is_uninstall
                else "Activar autologin de LightDM"
            ),
            state=tk.NORMAL if not is_update else tk.DISABLED,
        )

        labels = {
            "Instalar": "Iniciar instalación",
            "Reparar": "Reparar instalación",
            "Actualizar": "Actualizar Gateway",
            "Desinstalar": "Desinstalar Gateway",
        }
        self.run_button.configure(text=labels[operation])

    def _validate(self) -> bool:
        if platform.system() != "Linux":
            messagebox.showerror(
                "Sistema no compatible",
                "Este instalador debe ejecutarse en el equipo Linux del Gateway.",
            )
            return False

        if os.geteuid() != 0 and shutil.which("pkexec") is None:
            messagebox.showerror(
                "Permisos no disponibles",
                "No se encontró pkexec. Instale policykit-1 o abra el instalador desde launcher.sh.",
            )
            return False

        if not self.app_dir.get().strip():
            messagebox.showerror("Dato requerido", "Seleccione un directorio.")
            return False

        if self.operation.get() in {"Instalar", "Reparar"}:
            if not Path(self.env_file.get()).is_file():
                messagebox.showerror(
                    "Configuración no encontrada",
                    "Seleccione un archivo .env válido.",
                )
                return False

        if self.operation.get() != "Desinstalar":
            if not self.repo_url.get().strip() or not self.git_ref.get().strip():
                messagebox.showerror(
                    "Dato requerido",
                    "Indique el repositorio y la rama o versión.",
                )
                return False
        return True

    def _build_command(self) -> list[str]:
        operation = self.operation.get()
        app_dir = self.app_dir.get().strip()
        install_user = getpass.getuser()

        if operation in {"Instalar", "Reparar"}:
            command = [
                str(ROOT_DIR / "scripts" / "install.sh"),
                "--repo-url",
                self.repo_url.get().strip(),
                "--ref",
                self.git_ref.get().strip(),
                "--app-dir",
                app_dir,
                "--env-file",
                self.env_file.get().strip(),
                "--install-user",
                install_user,
            ]
            if operation == "Reparar":
                command.append("--skip-system-packages")
            if self.autostart.get():
                command.append("--autostart")
            command.append("--service" if self.service.get() else "--no-service")
            if self.autologin.get():
                command.append("--autologin")
        elif operation == "Actualizar":
            command = [
                str(ROOT_DIR / "scripts" / "update.sh"),
                "--repo-url",
                self.repo_url.get().strip(),
                "--ref",
                self.git_ref.get().strip(),
                "--app-dir",
                app_dir,
                "--install-user",
                install_user,
            ]
        else:
            command = [
                str(ROOT_DIR / "scripts" / "uninstall.sh"),
                "--app-dir",
                app_dir,
                "--yes",
                "--install-user",
                install_user,
            ]
            if self.autostart.get():
                command.append("--remove-autostart")
            if self.autologin.get():
                command.append("--remove-autologin")

        if self.reboot_after.get():
            command.append("--reboot")
        if os.geteuid() != 0:
            command.insert(0, "pkexec")
        return command

    def _start(self) -> None:
        if self.process is not None or not self._validate():
            return

        operation = self.operation.get()
        if operation == "Desinstalar":
            confirmed = messagebox.askyesno(
                "Confirmar desinstalación",
                "Se eliminará el Gateway y su archivo .env instalado. ¿Desea continuar?",
                icon=messagebox.WARNING,
            )
            if not confirmed:
                return

        if self.reboot_after.get():
            confirmed = messagebox.askyesno(
                "Confirmar reinicio",
                "El equipo se reiniciará inmediatamente al terminar. ¿Desea continuar?",
            )
            if not confirmed:
                return

        command = self._build_command()
        self.launch_after_completion = (
            operation in {"Instalar", "Reparar"}
            and not self.service.get()
            and self.run_after.get()
        )
        self._append_log(f"\n=== {operation} Gateway ===\n")
        self.status.set("Trabajando...")
        self.run_button.configure(state=tk.DISABLED)
        self.progress.start(12)

        threading.Thread(
            target=self._run_command,
            args=(command,),
            daemon=True,
        ).start()

    def _run_command(self, command: list[str]) -> None:
        try:
            self.process = subprocess.Popen(
                command,
                cwd=ROOT_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert self.process.stdout is not None
            for line in self.process.stdout:
                self.output_queue.put(("line", line))
            return_code = self.process.wait()
            self.output_queue.put(("done", return_code))
        except Exception as error:
            self.output_queue.put(("error", str(error)))

    def _drain_output(self) -> None:
        try:
            while True:
                event, payload = self.output_queue.get_nowait()
                if event == "line":
                    self._append_log(str(payload))
                elif event == "done":
                    self._finish(int(payload))
                elif event == "error":
                    self._append_log(f"ERROR: {payload}\n")
                    self._finish(1)
        except queue.Empty:
            pass
        self.after(100, self._drain_output)

    def _append_log(self, message: str) -> None:
        self.log.configure(state=tk.NORMAL)
        self.log.insert(tk.END, message)
        self.log.see(tk.END)
        self.log.configure(state=tk.DISABLED)

    def _copy_log(self) -> None:
        content = self.log.get("1.0", tk.END).strip()
        self.clipboard_clear()
        self.clipboard_append(content)
        self.status.set("Actividad copiada")

    def _finish(self, return_code: int) -> None:
        self.process = None
        self.progress.stop()
        self.run_button.configure(state=tk.NORMAL)
        if return_code == 0:
            if self.launch_after_completion:
                try:
                    subprocess.Popen(
                        [str(Path(self.app_dir.get().strip()) / "start.sh")],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                    self._append_log("Gateway iniciado en la sesión gráfica.\n")
                except Exception as error:
                    self._append_log(f"No se pudo iniciar Gateway: {error}\n")
            self.status.set("Completado")
            self._append_log("Operación completada correctamente.\n")
            messagebox.showinfo("Operación completada", "El proceso terminó correctamente.")
        else:
            self.status.set("Error")
            self._append_log(f"El proceso terminó con código {return_code}.\n")
            messagebox.showerror(
                "No se pudo completar",
                "Revise el detalle mostrado en la sección Actividad.",
            )
        self.launch_after_completion = False


if __name__ == "__main__":
    GatewayInstaller().mainloop()
