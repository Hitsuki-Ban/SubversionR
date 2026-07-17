#[cfg(not(windows))]
#[test]
fn worker_containment_probe_is_windows_only() {
    eprintln!("SKIP: M8 worker containment requires Windows Job Objects and CreateProcessW");
}

#[cfg(windows)]
mod windows {
    use std::collections::BTreeSet;
    use std::env;
    use std::ffi::{OsStr, OsString, c_void};
    use std::fs::File;
    use std::io::{self, Read, Write};
    use std::mem::{ManuallyDrop, size_of, zeroed};
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::os::windows::io::{FromRawHandle, RawHandle};
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::ptr::{null, null_mut};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::thread;
    use std::time::{Duration, Instant};

    type Bool = i32;
    type Dword = u32;
    type Handle = *mut c_void;
    type SizeT = usize;

    const FALSE: Bool = 0;
    const TRUE: Bool = 1;
    const INVALID_HANDLE_VALUE: Handle = usize::MAX as Handle;
    const HANDLE_FLAG_INHERIT: Dword = 0x0000_0001;
    const GENERIC_READ: Dword = 0x8000_0000;
    const GENERIC_WRITE: Dword = 0x4000_0000;
    const OPEN_EXISTING: Dword = 3;
    const FILE_ATTRIBUTE_NORMAL: Dword = 0x0000_0080;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: Dword = 0x0008_0000;
    const FILE_FLAG_OVERLAPPED: Dword = 0x4000_0000;
    const PIPE_ACCESS_OUTBOUND: Dword = 0x0000_0002;
    const PIPE_TYPE_BYTE: Dword = 0;
    const PIPE_READMODE_BYTE: Dword = 0;
    const PIPE_WAIT: Dword = 0;
    const ERROR_IO_PENDING: i32 = 997;
    const STARTF_USESTDHANDLES: Dword = 0x0000_0100;
    const CREATE_SUSPENDED: Dword = 0x0000_0004;
    const CREATE_UNICODE_ENVIRONMENT: Dword = 0x0000_0400;
    const EXTENDED_STARTUPINFO_PRESENT: Dword = 0x0008_0000;
    const CREATE_NO_WINDOW: Dword = 0x0800_0000;
    const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x0002_0002;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: Dword = 0x0000_2000;
    const JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION_CLASS: Dword = 1;
    const JOB_OBJECT_BASIC_PROCESS_ID_LIST_CLASS: Dword = 3;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: Dword = 9;
    const PROCESS_QUERY_LIMITED_INFORMATION: Dword = 0x0000_1000;
    const SYNCHRONIZE: Dword = 0x0010_0000;
    const WAIT_OBJECT_0: Dword = 0;
    const WAIT_TIMEOUT: Dword = 258;
    const PRESSURE_BYTES: usize = 1024 * 1024;
    const PIPE_BUFFER_BYTES: Dword = 4096;
    const PROCESS_TIMEOUT: Duration = Duration::from_secs(30);
    const CLEANUP_TIMEOUT: Duration = Duration::from_secs(5);
    const NODE_OUTPUT_LIMIT: usize = 64 * 1024;
    const REQUEST_MAGIC: &[u8; 8] = b"M8REQ001";
    const RESULT_MAGIC: &[u8; 8] = b"M8DONE01";
    const PING_MAGIC: &[u8; 8] = b"M8PING01";
    const PONG_MAGIC: &[u8; 8] = b"M8PONG01";
    const PARENT_PATTERN: u8 = 0x5a;
    const WORKER_PATTERN: u8 = 0xa5;
    static PIPE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

    #[repr(C)]
    struct SecurityAttributes {
        length: Dword,
        security_descriptor: *mut c_void,
        inherit_handle: Bool,
    }

    #[repr(C)]
    struct StartupInfoW {
        cb: Dword,
        reserved: *mut u16,
        desktop: *mut u16,
        title: *mut u16,
        x: Dword,
        y: Dword,
        x_size: Dword,
        y_size: Dword,
        x_count_chars: Dword,
        y_count_chars: Dword,
        fill_attribute: Dword,
        flags: Dword,
        show_window: u16,
        reserved2_bytes: u16,
        reserved2: *mut u8,
        std_input: Handle,
        std_output: Handle,
        std_error: Handle,
    }

    #[repr(C)]
    struct StartupInfoExW {
        startup_info: StartupInfoW,
        attribute_list: *mut c_void,
    }

    #[repr(C)]
    struct ProcessInformation {
        process: Handle,
        thread: Handle,
        process_id: Dword,
        thread_id: Dword,
    }

    #[repr(C)]
    struct Overlapped {
        internal: usize,
        internal_high: usize,
        offset: Dword,
        offset_high: Dword,
        event: Handle,
    }

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: Dword,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: Dword,
        affinity: usize,
        priority_class: Dword,
        scheduling_class: Dword,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    #[repr(C)]
    #[derive(Default, Debug, Clone, Copy)]
    struct JobObjectBasicAccountingInformation {
        total_user_time: i64,
        total_kernel_time: i64,
        this_period_total_user_time: i64,
        this_period_total_kernel_time: i64,
        total_page_fault_count: Dword,
        total_processes: Dword,
        active_processes: Dword,
        total_terminated_processes: Dword,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectBasicProcessIdList {
        number_of_assigned_processes: Dword,
        number_of_process_ids_in_list: Dword,
        process_id_list: [usize; 16],
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreatePipe(
            read_pipe: *mut Handle,
            write_pipe: *mut Handle,
            pipe_attributes: *mut SecurityAttributes,
            size: Dword,
        ) -> Bool;
        fn CreateNamedPipeW(
            name: *const u16,
            open_mode: Dword,
            pipe_mode: Dword,
            maximum_instances: Dword,
            output_buffer_size: Dword,
            input_buffer_size: Dword,
            default_timeout: Dword,
            security_attributes: *mut SecurityAttributes,
        ) -> Handle;
        fn SetHandleInformation(handle: Handle, mask: Dword, flags: Dword) -> Bool;
        fn GetHandleInformation(handle: Handle, flags: *mut Dword) -> Bool;
        fn CreateFileW(
            file_name: *const u16,
            desired_access: Dword,
            share_mode: Dword,
            security_attributes: *mut SecurityAttributes,
            creation_disposition: Dword,
            flags_and_attributes: Dword,
            template_file: Handle,
        ) -> Handle;
        fn CreateEventW(
            event_attributes: *mut SecurityAttributes,
            manual_reset: Bool,
            initial_state: Bool,
            name: *const u16,
        ) -> Handle;
        fn SetEvent(event: Handle) -> Bool;
        fn WriteFile(
            file: Handle,
            buffer: *const c_void,
            bytes_to_write: Dword,
            bytes_written: *mut Dword,
            overlapped: *mut Overlapped,
        ) -> Bool;
        fn GetOverlappedResult(
            file: Handle,
            overlapped: *mut Overlapped,
            bytes_transferred: *mut Dword,
            wait: Bool,
        ) -> Bool;
        fn CloseHandle(handle: Handle) -> Bool;
        fn InitializeProcThreadAttributeList(
            attribute_list: *mut c_void,
            attribute_count: Dword,
            flags: Dword,
            size: *mut SizeT,
        ) -> Bool;
        fn UpdateProcThreadAttribute(
            attribute_list: *mut c_void,
            flags: Dword,
            attribute: usize,
            value: *mut c_void,
            size: SizeT,
            previous_value: *mut c_void,
            return_size: *mut SizeT,
        ) -> Bool;
        fn DeleteProcThreadAttributeList(attribute_list: *mut c_void);
        fn CreateProcessW(
            application_name: *const u16,
            command_line: *mut u16,
            process_attributes: *mut SecurityAttributes,
            thread_attributes: *mut SecurityAttributes,
            inherit_handles: Bool,
            creation_flags: Dword,
            environment: *mut c_void,
            current_directory: *const u16,
            startup_info: *mut StartupInfoW,
            process_information: *mut ProcessInformation,
        ) -> Bool;
        fn ResumeThread(thread: Handle) -> Dword;
        fn TerminateProcess(process: Handle, exit_code: u32) -> Bool;
        fn CreateJobObjectW(attributes: *mut SecurityAttributes, name: *const u16) -> Handle;
        fn SetInformationJobObject(
            job: Handle,
            information_class: Dword,
            information: *const c_void,
            information_length: Dword,
        ) -> Bool;
        fn QueryInformationJobObject(
            job: Handle,
            information_class: Dword,
            information: *mut c_void,
            information_length: Dword,
            return_length: *mut Dword,
        ) -> Bool;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> Bool;
        fn TerminateJobObject(job: Handle, exit_code: u32) -> Bool;
        fn IsProcessInJob(process: Handle, job: Handle, result: *mut Bool) -> Bool;
        fn OpenProcess(desired_access: Dword, inherit_handle: Bool, process_id: Dword) -> Handle;
        fn GetCurrentProcess() -> Handle;
        fn WaitForSingleObject(handle: Handle, milliseconds: Dword) -> Dword;
        fn WaitForMultipleObjects(
            count: Dword,
            handles: *const Handle,
            wait_all: Bool,
            milliseconds: Dword,
        ) -> Dword;
        fn GetExitCodeProcess(process: Handle, exit_code: *mut Dword) -> Bool;
        fn SearchPathW(
            path: *const u16,
            file_name: *const u16,
            extension: *const u16,
            buffer_length: Dword,
            buffer: *mut u16,
            file_part: *mut *mut u16,
        ) -> Dword;
    }

    #[derive(Debug)]
    struct OwnedHandle(Handle);

    unsafe impl Send for OwnedHandle {}

    impl OwnedHandle {
        fn new(handle: Handle, context: &str) -> io::Result<Self> {
            if handle.is_null() || handle == INVALID_HANDLE_VALUE {
                return Err(context_error(context));
            }
            Ok(Self(handle))
        }

        fn raw(&self) -> Handle {
            self.0
        }

        fn into_file(self) -> File {
            let this = ManuallyDrop::new(self);
            // SAFETY: ownership of this valid handle moves from OwnedHandle to File exactly once.
            unsafe { File::from_raw_handle(this.0 as RawHandle) }
        }
    }

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
                // SAFETY: this RAII value exclusively owns the valid kernel handle.
                unsafe {
                    CloseHandle(self.0);
                }
                self.0 = null_mut();
            }
        }
    }

    struct AttributeList {
        storage: Vec<usize>,
    }

    impl AttributeList {
        fn with_handles(handles: &[Handle]) -> io::Result<Self> {
            let mut bytes = 0usize;
            // SAFETY: the documented sizing call uses a null list and writes only the size.
            unsafe {
                InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut bytes);
            }
            if bytes == 0 {
                return Err(context_error("InitializeProcThreadAttributeList sizing"));
            }
            let words = bytes.div_ceil(size_of::<usize>());
            let mut storage = vec![0usize; words];
            let pointer = storage.as_mut_ptr().cast::<c_void>();
            let mut initialized_bytes = bytes;
            // SAFETY: storage is aligned and sized from the required sizing call.
            if unsafe { InitializeProcThreadAttributeList(pointer, 1, 0, &mut initialized_bytes) }
                == FALSE
            {
                return Err(context_error(
                    "InitializeProcThreadAttributeList initialize",
                ));
            }
            // SAFETY: the handle array and attribute storage remain alive through CreateProcessW.
            if unsafe {
                UpdateProcThreadAttribute(
                    pointer,
                    0,
                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                    handles.as_ptr().cast_mut().cast::<c_void>(),
                    std::mem::size_of_val(handles),
                    null_mut(),
                    null_mut(),
                )
            } == FALSE
            {
                // SAFETY: the preceding initialize call succeeded.
                unsafe {
                    DeleteProcThreadAttributeList(pointer);
                }
                return Err(context_error("UpdateProcThreadAttribute handle list"));
            }
            Ok(Self { storage })
        }

        fn pointer(&mut self) -> *mut c_void {
            self.storage.as_mut_ptr().cast::<c_void>()
        }
    }

    impl Drop for AttributeList {
        fn drop(&mut self) {
            // SAFETY: the list was initialized successfully and is deleted exactly once.
            unsafe {
                DeleteProcThreadAttributeList(self.storage.as_mut_ptr().cast::<c_void>());
            }
        }
    }

    struct PipeEnds {
        read: OwnedHandle,
        write: OwnedHandle,
    }

    struct SuspendedChild {
        process: Option<OwnedHandle>,
        thread: Option<OwnedHandle>,
        process_id: Dword,
    }

    impl SuspendedChild {
        fn process(&self) -> &OwnedHandle {
            self.process
                .as_ref()
                .expect("suspended child process handle must exist")
        }

        fn thread(&self) -> &OwnedHandle {
            self.thread
                .as_ref()
                .expect("suspended child thread handle must exist")
        }

        fn into_parts(mut self) -> (OwnedHandle, OwnedHandle) {
            let process = self
                .process
                .take()
                .expect("suspended child process handle must exist");
            let thread = self
                .thread
                .take()
                .expect("suspended child thread handle must exist");
            (process, thread)
        }
    }

    impl Drop for SuspendedChild {
        fn drop(&mut self) {
            let Some(process) = self.process.as_ref() else {
                return;
            };
            // SAFETY: an armed SuspendedChild owns a live process handle. This cleanup is the
            // fail-safe for every error before ownership is transferred to Job supervision.
            unsafe {
                TerminateProcess(process.raw(), 0x4d3a);
                WaitForSingleObject(process.raw(), CLEANUP_TIMEOUT.as_millis() as Dword);
            }
        }
    }

    struct RunningControlProbe {
        process: OwnedHandle,
        input: File,
        output: File,
        excluded_sentinel: OwnedHandle,
        backpressure_observed: Option<OwnedHandle>,
    }

    #[derive(Clone, Copy)]
    enum CleanupProof {
        HardStop,
        JobCloseBackstop,
    }

    fn context_error(context: &str) -> io::Error {
        let source = io::Error::last_os_error();
        io::Error::new(source.kind(), format!("{context}: {source}"))
    }

    fn inheritable_attributes() -> SecurityAttributes {
        SecurityAttributes {
            length: size_of::<SecurityAttributes>() as Dword,
            security_descriptor: null_mut(),
            inherit_handle: TRUE,
        }
    }

    fn create_pipe() -> io::Result<PipeEnds> {
        let mut read = null_mut();
        let mut write = null_mut();
        let mut attributes = inheritable_attributes();
        // SAFETY: output pointers and SECURITY_ATTRIBUTES are valid for the call.
        if unsafe { CreatePipe(&mut read, &mut write, &mut attributes, PIPE_BUFFER_BYTES) } == FALSE
        {
            return Err(context_error("CreatePipe"));
        }
        Ok(PipeEnds {
            read: OwnedHandle::new(read, "CreatePipe read handle")?,
            write: OwnedHandle::new(write, "CreatePipe write handle")?,
        })
    }

    fn create_overlapped_outbound_pipe() -> io::Result<PipeEnds> {
        let sequence = PIPE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let name = format!(r"\\.\pipe\SubversionR-M8-{}-{sequence}", std::process::id());
        let name_wide = wide_null(OsStr::new(&name))?;
        let mut attributes = inheritable_attributes();
        // SAFETY: the unique pipe name and SECURITY_ATTRIBUTES remain valid through the call.
        let write = OwnedHandle::new(
            unsafe {
                CreateNamedPipeW(
                    name_wide.as_ptr(),
                    PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                    1,
                    PIPE_BUFFER_BYTES,
                    PIPE_BUFFER_BYTES,
                    0,
                    &mut attributes,
                )
            },
            "CreateNamedPipeW overlapped outbound",
        )?;
        // SAFETY: CreateFileW connects the local read-only client to the unique server instance.
        let read = OwnedHandle::new(
            unsafe {
                CreateFileW(
                    name_wide.as_ptr(),
                    GENERIC_READ,
                    0,
                    null_mut(),
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    null_mut(),
                )
            },
            "CreateFileW overlapped outbound client",
        )?;
        Ok(PipeEnds { read, write })
    }

    fn clear_inherit(handle: &OwnedHandle) -> io::Result<()> {
        // SAFETY: handle is valid and owned by this process.
        if unsafe { SetHandleInformation(handle.raw(), HANDLE_FLAG_INHERIT, 0) } == FALSE {
            return Err(context_error("SetHandleInformation clear inherit"));
        }
        Ok(())
    }

    fn open_inheritable_nul(access: Dword) -> io::Result<OwnedHandle> {
        let name = wide_null(OsStr::new("NUL"))?;
        let mut attributes = inheritable_attributes();
        // SAFETY: the NUL path and SECURITY_ATTRIBUTES live for the duration of the call.
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                access,
                0,
                &mut attributes,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                null_mut(),
            )
        };
        OwnedHandle::new(handle, "CreateFileW NUL")
    }

    fn create_inheritable_sentinel() -> io::Result<OwnedHandle> {
        let mut attributes = inheritable_attributes();
        // SAFETY: SECURITY_ATTRIBUTES is valid and the event is unnamed.
        let handle = unsafe { CreateEventW(&mut attributes, FALSE, FALSE, null()) };
        OwnedHandle::new(handle, "CreateEventW sentinel")
    }

    fn create_inheritable_backpressure_event() -> io::Result<OwnedHandle> {
        let mut attributes = inheritable_attributes();
        // SAFETY: SECURITY_ATTRIBUTES is valid and the auto-reset event is unnamed.
        let handle = unsafe { CreateEventW(&mut attributes, FALSE, FALSE, null()) };
        OwnedHandle::new(handle, "CreateEventW backpressure observation")
    }

    fn create_overlapped_completion_event() -> io::Result<OwnedHandle> {
        // SAFETY: the manual-reset event is unnamed and intentionally non-inheritable.
        let handle = unsafe { CreateEventW(null_mut(), TRUE, FALSE, null()) };
        OwnedHandle::new(handle, "CreateEventW overlapped completion")
    }

    fn require_inheritable(handle: Handle) -> io::Result<()> {
        let mut flags = 0;
        // SAFETY: handle is expected to be a valid kernel handle.
        if unsafe { GetHandleInformation(handle, &mut flags) } == FALSE {
            return Err(context_error("GetHandleInformation allowlist"));
        }
        if flags & HANDLE_FLAG_INHERIT == 0 {
            return Err(io::Error::other("allowlisted handle is not inheritable"));
        }
        Ok(())
    }

    fn wide_null(value: &OsStr) -> io::Result<Vec<u16>> {
        let mut wide = value.encode_wide().collect::<Vec<_>>();
        if wide.contains(&0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Windows string contains an embedded NUL",
            ));
        }
        wide.push(0);
        Ok(wide)
    }

    fn quote_windows_argument(value: &OsStr) -> io::Result<String> {
        let value = value.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "argument is not Unicode")
        })?;
        if value.contains('\0') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "argument contains an embedded NUL",
            ));
        }
        if !value.is_empty()
            && !value
                .chars()
                .any(|character| character.is_whitespace() || character == '"')
        {
            return Ok(value.to_string());
        }

        let mut quoted = String::from("\"");
        let mut backslashes = 0usize;
        for character in value.chars() {
            if character == '\\' {
                backslashes += 1;
            } else if character == '"' {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            } else {
                quoted.push_str(&"\\".repeat(backslashes));
                backslashes = 0;
                quoted.push(character);
            }
        }
        quoted.push_str(&"\\".repeat(backslashes * 2));
        quoted.push('"');
        Ok(quoted)
    }

    fn command_line(application: &Path, arguments: &[OsString]) -> io::Result<Vec<u16>> {
        let mut parts = Vec::with_capacity(arguments.len() + 1);
        parts.push(quote_windows_argument(application.as_os_str())?);
        for argument in arguments {
            parts.push(quote_windows_argument(argument)?);
        }
        wide_null(OsStr::new(&parts.join(" ")))
    }

    fn required_environment(extra: &[(&str, String)]) -> io::Result<Vec<u16>> {
        let mut entries = Vec::new();
        for name in ["SystemRoot", "WINDIR", "TEMP", "TMP"] {
            let value = env::var(name).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("required environment variable {name} is missing"),
                )
            })?;
            entries.push((name.to_string(), value));
        }
        for (name, value) in extra {
            if name.is_empty() || name.contains('=') || name.contains('\0') || value.contains('\0')
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid explicit environment entry",
                ));
            }
            if entries
                .iter()
                .any(|(existing, _)| existing.eq_ignore_ascii_case(name))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("duplicate environment entry {name}"),
                ));
            }
            entries.push(((*name).to_string(), value.clone()));
        }
        entries.sort_by_key(|(name, _)| name.to_ascii_uppercase());

        let mut block = Vec::new();
        for (name, value) in entries {
            block.extend(OsStr::new(&format!("{name}={value}")).encode_wide());
            block.push(0);
        }
        block.push(0);
        Ok(block)
    }

    fn spawn_suspended(
        application: &Path,
        arguments: &[OsString],
        std_input: Handle,
        std_output: Handle,
        std_error: Handle,
        extra_allowed_handles: &[Handle],
        extra_environment: &[(&str, String)],
    ) -> io::Result<SuspendedChild> {
        if !application.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "probe executable path must be absolute",
            ));
        }

        let mut unique = BTreeSet::new();
        let mut handles = Vec::new();
        for handle in [std_input, std_output, std_error]
            .into_iter()
            .chain(extra_allowed_handles.iter().copied())
        {
            if unique.insert(handle as usize) {
                require_inheritable(handle)?;
                handles.push(handle);
            }
        }
        if handles.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "the inherited-handle allowlist must not be empty",
            ));
        }

        let mut attributes = AttributeList::with_handles(&handles)?;
        let mut startup: StartupInfoExW = unsafe { zeroed() };
        startup.startup_info.cb = size_of::<StartupInfoExW>() as Dword;
        startup.startup_info.flags = STARTF_USESTDHANDLES;
        startup.startup_info.std_input = std_input;
        startup.startup_info.std_output = std_output;
        startup.startup_info.std_error = std_error;
        startup.attribute_list = attributes.pointer();

        let application_wide = wide_null(application.as_os_str())?;
        let mut command_line = command_line(application, arguments)?;
        let mut environment = required_environment(extra_environment)?;
        let mut process_information: ProcessInformation = unsafe { zeroed() };
        // SAFETY: every pointer references initialized storage that remains alive through the call.
        let created = unsafe {
            CreateProcessW(
                application_wide.as_ptr(),
                command_line.as_mut_ptr(),
                null_mut(),
                null_mut(),
                TRUE,
                CREATE_SUSPENDED
                    | CREATE_NO_WINDOW
                    | CREATE_UNICODE_ENVIRONMENT
                    | EXTENDED_STARTUPINFO_PRESENT,
                environment.as_mut_ptr().cast::<c_void>(),
                null(),
                &mut startup.startup_info,
                &mut process_information,
            )
        };
        if created == FALSE {
            return Err(context_error("CreateProcessW suspended probe"));
        }
        Ok(SuspendedChild {
            process: Some(OwnedHandle::new(
                process_information.process,
                "CreateProcessW process",
            )?),
            thread: Some(OwnedHandle::new(
                process_information.thread,
                "CreateProcessW thread",
            )?),
            process_id: process_information.process_id,
        })
    }

    fn new_kill_on_close_job() -> io::Result<OwnedHandle> {
        // SAFETY: the job is unnamed and uses the default security descriptor.
        let job = OwnedHandle::new(
            unsafe { CreateJobObjectW(null_mut(), null()) },
            "CreateJobObjectW",
        )?;
        let mut limits = JobObjectExtendedLimitInformation::default();
        limits.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: the information pointer and exact structure size are valid.
        if unsafe {
            SetInformationJobObject(
                job.raw(),
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                (&limits as *const JobObjectExtendedLimitInformation).cast::<c_void>(),
                size_of::<JobObjectExtendedLimitInformation>() as Dword,
            )
        } == FALSE
        {
            return Err(context_error("SetInformationJobObject KILL_ON_JOB_CLOSE"));
        }
        Ok(job)
    }

    fn assign_and_resume(job: &OwnedHandle, child: &mut SuspendedChild) -> io::Result<()> {
        // SAFETY: both handles are valid and the child primary thread is still suspended.
        if unsafe { AssignProcessToJobObject(job.raw(), child.process().raw()) } == FALSE {
            return Err(context_error(
                "AssignProcessToJobObject nested operation job",
            ));
        }
        if !process_is_in_job(child.process().raw(), job.raw())? {
            return Err(io::Error::other(
                "assigned worker is not observable in its operation Job",
            ));
        }
        // SAFETY: this is the primary thread handle returned by CREATE_SUSPENDED.
        let previous_count = unsafe { ResumeThread(child.thread().raw()) };
        if previous_count != 1 {
            return Err(if previous_count == Dword::MAX {
                context_error("ResumeThread")
            } else {
                io::Error::other(format!(
                    "ResumeThread expected previous suspend count 1, got {previous_count}"
                ))
            });
        }
        Ok(())
    }

    fn process_is_in_job(process: Handle, job: Handle) -> io::Result<bool> {
        let mut result = FALSE;
        // SAFETY: process is a valid process handle or the documented current-process pseudo handle.
        if unsafe { IsProcessInJob(process, job, &mut result) } == FALSE {
            return Err(context_error("IsProcessInJob"));
        }
        Ok(result != FALSE)
    }

    fn current_process_is_in_any_job() -> io::Result<bool> {
        // SAFETY: GetCurrentProcess returns the documented pseudo handle for this process.
        process_is_in_job(unsafe { GetCurrentProcess() }, null_mut())
    }

    fn job_accounting(job: &OwnedHandle) -> io::Result<JobObjectBasicAccountingInformation> {
        let mut accounting = JobObjectBasicAccountingInformation::default();
        // SAFETY: output pointer and exact structure size are valid.
        if unsafe {
            QueryInformationJobObject(
                job.raw(),
                JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION_CLASS,
                (&mut accounting as *mut JobObjectBasicAccountingInformation).cast::<c_void>(),
                size_of::<JobObjectBasicAccountingInformation>() as Dword,
                null_mut(),
            )
        } == FALSE
        {
            return Err(context_error("QueryInformationJobObject accounting"));
        }
        Ok(accounting)
    }

    fn wait_for_job_process_count(
        job: &OwnedHandle,
        predicate: impl Fn(JobObjectBasicAccountingInformation) -> bool,
        description: &str,
    ) -> io::Result<JobObjectBasicAccountingInformation> {
        let deadline = Instant::now() + CLEANUP_TIMEOUT;
        loop {
            let accounting = job_accounting(job)?;
            if predicate(accounting) {
                return Ok(accounting);
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("timed out waiting for Job accounting: {description}"),
                ));
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn snapshot_job_processes(job: &OwnedHandle) -> io::Result<Vec<OwnedHandle>> {
        let mut process_ids = JobObjectBasicProcessIdList::default();
        // SAFETY: the output buffer has fixed capacity for this two-process bounded probe.
        if unsafe {
            QueryInformationJobObject(
                job.raw(),
                JOB_OBJECT_BASIC_PROCESS_ID_LIST_CLASS,
                (&mut process_ids as *mut JobObjectBasicProcessIdList).cast::<c_void>(),
                size_of::<JobObjectBasicProcessIdList>() as Dword,
                null_mut(),
            )
        } == FALSE
        {
            return Err(context_error("QueryInformationJobObject process list"));
        }
        if process_ids.number_of_assigned_processes != process_ids.number_of_process_ids_in_list {
            return Err(io::Error::other(format!(
                "bounded Job process snapshot was incomplete: assigned {}, listed {}",
                process_ids.number_of_assigned_processes, process_ids.number_of_process_ids_in_list
            )));
        }
        if process_ids.number_of_process_ids_in_list < 2 {
            return Err(io::Error::other(
                "Job process snapshot did not include both worker and descendant",
            ));
        }

        process_ids.process_id_list[..process_ids.number_of_process_ids_in_list as usize]
            .iter()
            .map(|process_id| {
                let process_id = Dword::try_from(*process_id).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidData, "process ID exceeds DWORD")
                })?;
                // SAFETY: the snapshotted PID belongs to a process held alive in the Job probe.
                OwnedHandle::new(
                    unsafe {
                        OpenProcess(
                            SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                            FALSE,
                            process_id,
                        )
                    },
                    "OpenProcess Job member",
                )
            })
            .collect()
    }

    fn probe_filter(mode: &str) -> io::Result<&'static str> {
        match mode {
            "pressure" => Ok("windows::worker_fixture_entry"),
            "ping" => Ok("windows::ping_fixture_entry"),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "unknown worker probe mode",
            )),
        }
    }

    fn spawn_control_probe(job: &OwnedHandle, mode: &str) -> io::Result<RunningControlProbe> {
        let inbound = create_pipe()?;
        let outbound = match mode {
            "pressure" => create_overlapped_outbound_pipe()?,
            "ping" => create_pipe()?,
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unknown worker probe mode",
                ));
            }
        };
        clear_inherit(&inbound.write)?;
        clear_inherit(&outbound.read)?;
        let nul_read = open_inheritable_nul(GENERIC_READ)?;
        let nul_write = open_inheritable_nul(GENERIC_WRITE)?;
        let sentinel = create_inheritable_sentinel()?;
        let backpressure_observed = match mode {
            "pressure" => Some(create_inheritable_backpressure_event()?),
            "ping" => None,
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unknown worker probe mode",
                ));
            }
        };
        let executable = env::current_exe()?;
        let filter = probe_filter(mode)?;
        let arguments = [
            OsString::from("--exact"),
            OsString::from(filter),
            OsString::from("--nocapture"),
            OsString::from("--test-threads=1"),
        ];
        let mut extra_environment = vec![
            ("SUBVERSIONR_M8_PROBE_MODE", mode.to_string()),
            (
                "SUBVERSIONR_M8_CONTROL_READ_HANDLE",
                (inbound.read.raw() as usize).to_string(),
            ),
            (
                "SUBVERSIONR_M8_CONTROL_WRITE_HANDLE",
                (outbound.write.raw() as usize).to_string(),
            ),
            (
                "SUBVERSIONR_M8_EXCLUDED_SENTINEL_HANDLE",
                (sentinel.raw() as usize).to_string(),
            ),
        ];
        let mut extra_allowed_handles = vec![inbound.read.raw(), outbound.write.raw()];
        if let Some(event) = &backpressure_observed {
            extra_allowed_handles.push(event.raw());
            extra_environment.push((
                "SUBVERSIONR_M8_BACKPRESSURE_OBSERVED_HANDLE",
                (event.raw() as usize).to_string(),
            ));
        }
        let mut child = spawn_suspended(
            &executable,
            &arguments,
            nul_read.raw(),
            nul_write.raw(),
            nul_write.raw(),
            &extra_allowed_handles,
            &extra_environment,
        )?;
        assign_and_resume(job, &mut child)?;
        let (process, thread) = child.into_parts();
        drop(thread);
        drop(inbound.read);
        drop(outbound.write);
        drop(nul_read);
        drop(nul_write);
        Ok(RunningControlProbe {
            process,
            input: inbound.write.into_file(),
            output: outbound.read.into_file(),
            excluded_sentinel: sentinel,
            backpressure_observed,
        })
    }

    fn parse_required_handle(name: &str) -> OwnedHandle {
        let value = env::var(name)
            .unwrap_or_else(|_| panic!("required probe environment variable {name} is missing"));
        let raw = value
            .parse::<usize>()
            .unwrap_or_else(|_| panic!("probe handle {name} is not an unsigned integer"))
            as Handle;
        let mut flags = 0;
        // SAFETY: validation is performed before ownership is accepted.
        assert_ne!(
            unsafe { GetHandleInformation(raw, &mut flags) },
            FALSE,
            "probe handle {name} is not valid"
        );
        OwnedHandle(raw)
    }

    fn signal_excluded_sentinel_if_present() {
        let value = env::var("SUBVERSIONR_M8_EXCLUDED_SENTINEL_HANDLE")
            .expect("excluded sentinel handle value is required");
        let raw = value
            .parse::<usize>()
            .expect("excluded sentinel handle must be numeric") as Handle;
        let mut flags = 0;
        // SAFETY: a valid handle at this numeric slot may be the inherited event or an unrelated
        // handle allocated by the child runtime. SetEvent is used only as an identity challenge;
        // the parent decides whether its specific event was signalled.
        if unsafe { GetHandleInformation(raw, &mut flags) } != FALSE {
            unsafe {
                SetEvent(raw);
            }
        }
    }

    fn require_sentinel_not_inherited(sentinel: &OwnedHandle) -> io::Result<()> {
        // SAFETY: sentinel is the valid parent event used for the object-identity challenge.
        match unsafe { WaitForSingleObject(sentinel.raw(), 0) } {
            WAIT_TIMEOUT => Ok(()),
            WAIT_OBJECT_0 => Err(io::Error::other(
                "a non-allowlisted inheritable sentinel leaked into the worker",
            )),
            _ => Err(context_error("WaitForSingleObject excluded sentinel")),
        }
    }

    fn write_repeated(writer: &mut File, byte: u8, count: usize) -> io::Result<()> {
        let chunk = [byte; 8192];
        let mut remaining = count;
        while remaining > 0 {
            let length = remaining.min(chunk.len());
            writer.write_all(&chunk[..length])?;
            remaining -= length;
        }
        writer.flush()
    }

    fn read_repeated(reader: &mut File, byte: u8, count: usize) -> io::Result<()> {
        let mut chunk = [0u8; 8192];
        let mut remaining = count;
        while remaining > 0 {
            let length = remaining.min(chunk.len());
            reader.read_exact(&mut chunk[..length])?;
            if chunk[..length].iter().any(|value| *value != byte) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "duplex pressure payload did not match its bounded pattern",
                ));
            }
            remaining -= length;
        }
        Ok(())
    }

    fn wait_for_backpressure_observation(
        event: &OwnedHandle,
        process: &OwnedHandle,
    ) -> io::Result<()> {
        let handles = [event.raw(), process.raw()];
        let milliseconds = u32::try_from(PROCESS_TIMEOUT.as_millis())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "timeout is too large"))?;
        // SAFETY: both array entries are valid waitable handles for the duration of the call.
        match unsafe {
            WaitForMultipleObjects(
                handles.len() as Dword,
                handles.as_ptr(),
                FALSE,
                milliseconds,
            )
        } {
            WAIT_OBJECT_0 => Ok(()),
            value if value == WAIT_OBJECT_0 + 1 => {
                let exit_code = process_exit_code(process)?;
                Err(io::Error::other(format!(
                    "worker exited with {exit_code} before confirming pipe backpressure"
                )))
            }
            WAIT_TIMEOUT => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for the worker to confirm pipe backpressure",
            )),
            _ => Err(context_error(
                "WaitForMultipleObjects backpressure observation",
            )),
        }
    }

    fn run_pressure_exchange(
        mut input: File,
        mut output: File,
        backpressure_observed: &OwnedHandle,
        process: &OwnedHandle,
    ) -> io::Result<(File, File)> {
        let writer = thread::spawn(move || -> io::Result<File> {
            input.write_all(REQUEST_MAGIC)?;
            input.write_all(&(PRESSURE_BYTES as u64).to_le_bytes())?;
            write_repeated(&mut input, PARENT_PATTERN, PRESSURE_BYTES)?;
            Ok(input)
        });

        wait_for_backpressure_observation(backpressure_observed, process)?;
        read_repeated(&mut output, WORKER_PATTERN, PRESSURE_BYTES)?;
        let mut marker = [0u8; RESULT_MAGIC.len()];
        output.read_exact(&mut marker)?;
        if &marker != RESULT_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "worker completion marker is invalid",
            ));
        }
        let input = writer
            .join()
            .map_err(|_| io::Error::other("parent pressure writer panicked"))??;
        Ok((input, output))
    }

    fn required_child_environment(command: &mut Command) {
        command.env_clear();
        for name in ["SystemRoot", "WINDIR", "TEMP", "TMP"] {
            let value = env::var(name)
                .unwrap_or_else(|_| panic!("required environment variable {name} is missing"));
            command.env(name, value);
        }
    }

    fn spawn_residue_descendant() {
        let executable = env::current_exe().expect("current probe executable must resolve");
        let mut command = Command::new(executable);
        command
            .args([
                "--exact",
                "windows::descendant_fixture_entry",
                "--nocapture",
                "--test-threads=1",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);
        required_child_environment(&mut command);
        command.env("SUBVERSIONR_M8_DESCENDANT_MODE", "1");
        command
            .spawn()
            .expect("residue descendant must spawn inside the inherited Job");
    }

    fn run_containment_probe(
        require_parent_job: bool,
        cleanup_proof: CleanupProof,
    ) -> io::Result<()> {
        if require_parent_job && !current_process_is_in_any_job()? {
            return Err(io::Error::other(
                "Node-launched daemon fixture is not inside the synthetic parent Job",
            ));
        }

        let operation_job = new_kill_on_close_job()?;
        let probe = spawn_control_probe(&operation_job, "pressure")?;
        let backpressure_observed = probe.backpressure_observed.as_ref().ok_or_else(|| {
            io::Error::other("pressure worker is missing its backpressure observation event")
        })?;
        let (input, output) = run_pressure_exchange(
            probe.input,
            probe.output,
            backpressure_observed,
            &probe.process,
        )?;
        require_sentinel_not_inherited(&probe.excluded_sentinel)?;
        let accounting = wait_for_job_process_count(
            &operation_job,
            |value| value.total_processes >= 2 && value.active_processes >= 2,
            "worker plus descendant to be active",
        )?;
        if accounting.total_processes < 2 {
            return Err(io::Error::other(
                "operation Job did not account for its descendant",
            ));
        }

        let cleanup_started = Instant::now();
        match cleanup_proof {
            CleanupProof::HardStop => {
                // SAFETY: the Job handle remains open for the authoritative ActiveProcesses query.
                if unsafe { TerminateJobObject(operation_job.raw(), 0x4d38) } == FALSE {
                    return Err(context_error("TerminateJobObject pressure worker"));
                }
                drop(probe.process);
                drop(input);
                drop(output);
                wait_for_job_process_count(
                    &operation_job,
                    |value| value.active_processes == 0,
                    "ActiveProcesses to reach zero after hard-stop",
                )?;
                drop(operation_job);
            }
            CleanupProof::JobCloseBackstop => {
                let supervised_processes = snapshot_job_processes(&operation_job)?;
                // This is the only operation Job handle. Closing it is the backstop under test:
                // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE must terminate every snapshotted member.
                drop(operation_job);
                drop(probe.process);
                drop(input);
                drop(output);
                for process in &supervised_processes {
                    wait_for_process(process, CLEANUP_TIMEOUT)?;
                }
            }
        }
        if cleanup_started.elapsed() > CLEANUP_TIMEOUT {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "worker-tree cleanup exceeded the bounded supervision budget",
            ));
        }

        let followup_job = new_kill_on_close_job()?;
        let mut followup = spawn_control_probe(&followup_job, "ping")?;
        followup.input.write_all(PING_MAGIC)?;
        followup.input.flush()?;
        let mut pong = [0u8; PONG_MAGIC.len()];
        followup.output.read_exact(&mut pong)?;
        require_sentinel_not_inherited(&followup.excluded_sentinel)?;
        if &pong != PONG_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "subsequent parent ping response is invalid",
            ));
        }
        wait_for_process(&followup.process, PROCESS_TIMEOUT)?;
        let exit_code = process_exit_code(&followup.process)?;
        if exit_code != 0 {
            return Err(io::Error::other(format!(
                "subsequent ping worker exited with {exit_code}"
            )));
        }
        drop(followup.process);
        drop(followup.input);
        drop(followup.output);
        wait_for_job_process_count(
            &followup_job,
            |value| value.active_processes == 0,
            "subsequent ping Job to become empty",
        )?;
        Ok(())
    }

    fn wait_for_process(process: &OwnedHandle, timeout: Duration) -> io::Result<()> {
        let milliseconds = u32::try_from(timeout.as_millis())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "timeout is too large"))?;
        // SAFETY: process is a valid waitable process handle.
        match unsafe { WaitForSingleObject(process.raw(), milliseconds) } {
            WAIT_OBJECT_0 => Ok(()),
            WAIT_TIMEOUT => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for probe process",
            )),
            _ => Err(context_error("WaitForSingleObject process")),
        }
    }

    fn process_exit_code(process: &OwnedHandle) -> io::Result<Dword> {
        let mut exit_code = 0;
        // SAFETY: process is a valid process handle.
        if unsafe { GetExitCodeProcess(process.raw(), &mut exit_code) } == FALSE {
            return Err(context_error("GetExitCodeProcess"));
        }
        Ok(exit_code)
    }

    fn read_bounded(mut file: File) -> io::Result<Vec<u8>> {
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take((NODE_OUTPUT_LIMIT + 1) as u64)
            .read_to_end(&mut bytes)?;
        if bytes.len() > NODE_OUTPUT_LIMIT {
            return Err(io::Error::other(
                "Node host output exceeded its bounded limit",
            ));
        }
        Ok(bytes)
    }

    fn resolve_node_executable() -> io::Result<PathBuf> {
        let file_name = wide_null(OsStr::new("node.exe"))?;
        let mut buffer = vec![0u16; 32_768];
        // SAFETY: buffer is writable and file_name is NUL terminated.
        let length = unsafe {
            SearchPathW(
                null(),
                file_name.as_ptr(),
                null(),
                buffer.len() as Dword,
                buffer.as_mut_ptr(),
                null_mut(),
            )
        };
        if length == 0 {
            return Err(context_error("SearchPathW node.exe"));
        }
        if length as usize >= buffer.len() {
            return Err(io::Error::other(
                "resolved node.exe path exceeds the fixed probe bound",
            ));
        }
        buffer.truncate(length as usize);
        let path = PathBuf::from(OsString::from_wide(&buffer));
        if !path.is_absolute() {
            return Err(io::Error::other(
                "SearchPathW returned a non-absolute node.exe path",
            ));
        }
        Ok(path)
    }

    fn run_node_host_shape() -> io::Result<()> {
        let node = resolve_node_executable()?;
        let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("m8_extension_host_launcher.cjs");
        if !script.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Node host fixture is missing",
            ));
        }
        let executable = env::current_exe()?;
        let host_job = new_kill_on_close_job()?;
        let stdout_pipe = create_pipe()?;
        let stderr_pipe = create_pipe()?;
        clear_inherit(&stdout_pipe.read)?;
        clear_inherit(&stderr_pipe.read)?;
        let nul_read = open_inheritable_nul(GENERIC_READ)?;
        let arguments = [
            script.into_os_string(),
            executable.into_os_string(),
            OsString::from("windows::node_host_fixture_entry"),
        ];
        let mut child = spawn_suspended(
            &node,
            &arguments,
            nul_read.raw(),
            stdout_pipe.write.raw(),
            stderr_pipe.write.raw(),
            &[],
            &[],
        )?;
        assign_and_resume(&host_job, &mut child)?;
        let (process, thread) = child.into_parts();
        drop(thread);
        drop(nul_read);
        drop(stdout_pipe.write);
        drop(stderr_pipe.write);

        let stdout_reader = thread::spawn(move || read_bounded(stdout_pipe.read.into_file()));
        let stderr_reader = thread::spawn(move || read_bounded(stderr_pipe.read.into_file()));
        if let Err(error) = wait_for_process(&process, PROCESS_TIMEOUT) {
            // SAFETY: host_job is a valid Job handle and bounds cleanup of the full host tree.
            unsafe {
                TerminateJobObject(host_job.raw(), 0x4d39);
            }
            return Err(error);
        }
        let exit_code = process_exit_code(&process)?;
        drop(process);
        let stdout = stdout_reader
            .join()
            .map_err(|_| io::Error::other("Node stdout reader panicked"))??;
        let stderr = stderr_reader
            .join()
            .map_err(|_| io::Error::other("Node stderr reader panicked"))??;
        wait_for_job_process_count(
            &host_job,
            |value| value.active_processes == 0,
            "synthetic Extension Host Job to become empty",
        )?;
        if exit_code != 0 {
            return Err(io::Error::other(format!(
                "Node Extension Host shape exited with {exit_code}; bounded stderr: {}",
                String::from_utf8_lossy(&stderr)
            )));
        }
        if !String::from_utf8_lossy(&stdout).contains("SUBVERSIONR_M8_NODE_HOST_OK") {
            return Err(io::Error::other(
                "Node Extension Host shape did not emit the success marker",
            ));
        }
        Ok(())
    }

    #[test]
    fn direct_worker_hard_stop_observes_active_processes_reach_zero() {
        run_containment_probe(false, CleanupProof::HardStop)
            .expect("TerminateJobObject hard-stop probe must pass");
    }

    #[test]
    fn job_close_backstop_terminates_worker_and_descendant_tree() {
        run_containment_probe(false, CleanupProof::JobCloseBackstop)
            .expect("KILL_ON_JOB_CLOSE backstop probe must pass");
    }

    #[test]
    fn unassigned_suspended_child_raii_terminates_and_waits() {
        let executable = env::current_exe().expect("probe executable must resolve");
        let nul_read = open_inheritable_nul(GENERIC_READ).expect("NUL read handle must open");
        let nul_write = open_inheritable_nul(GENERIC_WRITE).expect("NUL write handle must open");
        let arguments = [
            OsString::from("--exact"),
            OsString::from("windows::descendant_fixture_entry"),
            OsString::from("--nocapture"),
            OsString::from("--test-threads=1"),
        ];
        let child = spawn_suspended(
            &executable,
            &arguments,
            nul_read.raw(),
            nul_write.raw(),
            nul_write.raw(),
            &[],
            &[("SUBVERSIONR_M8_DESCENDANT_MODE", "1".to_string())],
        )
        .expect("unassigned suspended child must spawn");
        // SAFETY: the PID was returned with the still-suspended process handle.
        let supervisor = OwnedHandle::new(
            unsafe {
                OpenProcess(
                    SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                    FALSE,
                    child.process_id,
                )
            },
            "OpenProcess unassigned suspended child",
        )
        .expect("independent process supervisor must open");
        // SAFETY: supervisor is a valid waitable process handle.
        assert_eq!(
            unsafe { WaitForSingleObject(supervisor.raw(), 0) },
            WAIT_TIMEOUT
        );

        drop(child);

        wait_for_process(&supervisor, CLEANUP_TIMEOUT)
            .expect("SuspendedChild RAII must wait for termination");
        assert_eq!(
            process_exit_code(&supervisor).expect("RAII exit code must be observable"),
            0x4d3a
        );
    }

    #[test]
    fn node_extension_host_shape_supports_nested_operation_jobs() {
        run_node_host_shape().expect("Node Extension Host process-shape probe must pass");
    }

    #[test]
    fn node_host_fixture_entry() {
        if env::var("SUBVERSIONR_M8_NODE_HOST_MODE").as_deref() != Ok("1") {
            return;
        }
        run_containment_probe(true, CleanupProof::HardStop)
            .expect("nested Node host containment probe must pass");
        println!("SUBVERSIONR_M8_NODE_HOST_OK");
    }

    #[test]
    fn worker_fixture_entry() {
        if env::var("SUBVERSIONR_M8_PROBE_MODE").as_deref() != Ok("pressure") {
            return;
        }
        signal_excluded_sentinel_if_present();
        let input = parse_required_handle("SUBVERSIONR_M8_CONTROL_READ_HANDLE").into_file();
        let output = parse_required_handle("SUBVERSIONR_M8_CONTROL_WRITE_HANDLE");
        run_worker_pressure_fixture(input, output).expect("worker pressure fixture must complete");
    }

    fn overlapped(event: Handle) -> Overlapped {
        Overlapped {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event,
        }
    }

    fn write_overlapped_and_wait(output: &OwnedHandle, bytes: &[u8]) -> io::Result<()> {
        let completion = create_overlapped_completion_event()?;
        let mut operation = overlapped(completion.raw());
        // SAFETY: bytes and operation remain alive until synchronous or awaited completion.
        let initiated = unsafe {
            WriteFile(
                output.raw(),
                bytes.as_ptr().cast::<c_void>(),
                Dword::try_from(bytes.len()).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "write exceeds DWORD")
                })?,
                null_mut(),
                &mut operation,
            )
        };
        if initiated != FALSE {
            return Ok(());
        }
        let pending = io::Error::last_os_error();
        if pending.raw_os_error() != Some(ERROR_IO_PENDING) {
            return Err(io::Error::new(
                pending.kind(),
                format!("WriteFile overlapped marker: {pending}"),
            ));
        }
        let mut transferred = 0;
        // SAFETY: operation, completion event, and source bytes remain alive until completion.
        if unsafe { GetOverlappedResult(output.raw(), &mut operation, &mut transferred, TRUE) }
            == FALSE
        {
            return Err(context_error("GetOverlappedResult marker"));
        }
        if transferred as usize != bytes.len() {
            return Err(io::Error::other(format!(
                "overlapped marker write transferred {transferred} of {} bytes",
                bytes.len()
            )));
        }
        Ok(())
    }

    fn run_worker_pressure_fixture(mut input: File, output: OwnedHandle) -> io::Result<()> {
        let mut request_magic = [0u8; REQUEST_MAGIC.len()];
        input.read_exact(&mut request_magic)?;
        if &request_magic != REQUEST_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "request magic is invalid",
            ));
        }
        let mut length = [0u8; 8];
        input.read_exact(&mut length)?;
        let length = usize::try_from(u64::from_le_bytes(length)).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "pressure length is too large")
        })?;
        if length != PRESSURE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pressure length does not match the locked probe bound",
            ));
        }

        let pressure = vec![WORKER_PATTERN; PRESSURE_BYTES];
        let completion = create_overlapped_completion_event()?;
        let mut pressure_operation = overlapped(completion.raw());
        // SAFETY: the pressure buffer and OVERLAPPED state remain alive through completion.
        let initiated = unsafe {
            WriteFile(
                output.raw(),
                pressure.as_ptr().cast::<c_void>(),
                PRESSURE_BYTES as Dword,
                null_mut(),
                &mut pressure_operation,
            )
        };
        if initiated != FALSE {
            return Err(io::Error::other(
                "1 MiB write completed synchronously despite the undrained 4 KiB pipe",
            ));
        }
        let pending = io::Error::last_os_error();
        if pending.raw_os_error() != Some(ERROR_IO_PENDING) {
            return Err(io::Error::new(
                pending.kind(),
                format!("WriteFile pressure did not enter pending state: {pending}"),
            ));
        }

        let observation = parse_required_handle("SUBVERSIONR_M8_BACKPRESSURE_OBSERVED_HANDLE");
        // SAFETY: the parsed handle is an explicitly inherited auto-reset event.
        if unsafe { SetEvent(observation.raw()) } == FALSE {
            return Err(context_error("SetEvent backpressure observation"));
        }

        read_repeated(&mut input, PARENT_PATTERN, PRESSURE_BYTES)?;
        let mut transferred = 0;
        // SAFETY: all overlapped write state remains alive and the parent is now draining.
        if unsafe {
            GetOverlappedResult(
                output.raw(),
                &mut pressure_operation,
                &mut transferred,
                TRUE,
            )
        } == FALSE
        {
            return Err(context_error("GetOverlappedResult pressure"));
        }
        if transferred as usize != PRESSURE_BYTES {
            return Err(io::Error::other(format!(
                "overlapped pressure write transferred {transferred} of {PRESSURE_BYTES} bytes"
            )));
        }
        spawn_residue_descendant();
        write_overlapped_and_wait(&output, RESULT_MAGIC)?;

        let mut hold = [0u8; 1];
        input.read_exact(&mut hold)?;
        Err(io::Error::other(
            "pressure worker was released without Job termination",
        ))
    }

    #[test]
    fn ping_fixture_entry() {
        if env::var("SUBVERSIONR_M8_PROBE_MODE").as_deref() != Ok("ping") {
            return;
        }
        signal_excluded_sentinel_if_present();
        let mut input = parse_required_handle("SUBVERSIONR_M8_CONTROL_READ_HANDLE").into_file();
        let mut output = parse_required_handle("SUBVERSIONR_M8_CONTROL_WRITE_HANDLE").into_file();
        let mut ping = [0u8; PING_MAGIC.len()];
        input
            .read_exact(&mut ping)
            .expect("ping request must be readable");
        assert_eq!(&ping, PING_MAGIC);
        output
            .write_all(PONG_MAGIC)
            .expect("pong response must be writable");
        output.flush().expect("pong response must flush");
    }

    #[test]
    fn descendant_fixture_entry() {
        if env::var("SUBVERSIONR_M8_DESCENDANT_MODE").as_deref() != Ok("1") {
            return;
        }
        thread::sleep(Duration::from_secs(60));
        panic!("residue descendant escaped the operation Job termination");
    }
}
