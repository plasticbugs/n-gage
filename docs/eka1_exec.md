| svc | stub | called from | EKA2L1 |
|---|---|---|---|
| 800000 | 503ac504 | TFindChunk::Next |  |
| 000001 | 503ac508 | RChunk::Base | chunk_base |
| 000002 | 503ac50c | RChunk::Size | chunk_size |
| 000003 | 503ac518 | RChunk::MaxSize | chunk_max_size |
| 800006 | 503ac520 | TFindLogicalDevice::Next |  |
| 800007 | 503ac524 | RDevice::GetCaps |  |
| 800008 | 503ac528 | RDevice::QueryVersionSupported |  |
| 800009 | 503ac52c | RDevice::IsAvailable |  |
| 80000a | 503ac530 | TFindPhysicalDevice::Next |  |
| 80000b | 503ac534 | TFindLogicalChannel::Next |  |
| c0000c | 503ac538 | RBusLogicalChannel::DoRequest | logical_channel_do_request_eka1 |
| c0000d | 503ac53c | RBusLogicalChannel::DoCancel |  |
| c0000e | 503ac540 | RBusLogicalChannel::DoControl | logical_channel_do_control_eka1 |
| 80000f | 503ac550 | TFindLibrary::Next |  |
| 800010 | 503ac554 | RLibrary::Lookup | library_lookup_eka1 |
| 800011 | 503ac558 | RLibrary::EntryPoint | library_entry_point |
| 800012 | 503ac55c | RLibrary::DllRefTable |  |
| 800013 | 503ac560 | RChangeNotifier::LogonCancel |  |
| 800014 | 503ac564 | RChangeNotifier::LogonCancel |  |
| 800015 | 503ac568 | RLibrary::DllRefTable | library_attach |
| 800016 | 503ac56c | RLibrary::FileName | library_filename_eka1 |
| 800017 | 503ac570 | TFindMutex::Next |  |
| 000018 | 503ac574 | RMutex::Count | mutex_count_eka1 |
| 000019 | 503ac578 | RMutex::Wait | mutex_wait_eka1 |
| 00001a | 503ac57c | RMutex::Signal | mutex_signal_eka1 |
| 00001b | 503ac588 | RProcess::Id | process_id |
| 80001c | 503ac58c | TFindProcess::Next | process_find_next |
| c0001d | 503ac590 | RProcess::Resume | process_resume |
| 80001e | 503ac594 | RProcess::FileName | process_filename_eka1 |
| 80001f | 503ac598 | RProcess::CommandLine | process_command_line_eka1 |
| 000020 | 503ac5a0 | RProcess::ExitType | process_exit_type |
| 000021 | 503ac5a4 | RProcess::ExitReason | process_exit_reason |
| 000022 | 503ac5a8 | RProcess::ExitCategory |  |
| 000023 | 503ac5ac | RProcess::Priority |  |
| c00024 | 503ac5b0 | RProcess::SetPriority | process_set_priority_eka1 |
| 000025 | 503ac5b4 | RProcess::LoadedFromRam, RProcess::Protected, RProcess::System |  |
| c00026 | 503ac5b8 | RProcess::SetProtected, RProcess::SetSystem | process_set_flags_eka1 |
| c00027 | 503ac5bc | RProcess::SetOwner |  |
| 800028 | 503ac5c0 | TFindSemaphore::Next |  |
| 000029 | 503ac5c4 | RSemaphore::Count | semaphore_count_eka1 |
| 00002a | 503ac5c8 | RSemaphore::Wait | semaphore_wait_eka1 |
| c0002b | 503ac5cc | RSemaphore::Signal | semaphore_signal_eka1 |
| 80002c | 503ac5d0 | RSemaphore::Signal | semaphore_signal_n_eka1 |
| 80002d | 503ac5d4 | TFindServer::Next | server_find_next |
| c0002e | 503ac5d8 | CServer::RunL, RServer::Receive | server_receive |
| c0002f | 503ac5dc | RServer::Cancel | server_cancel |
| c00030 | 503ac5e0 | CServer::DoCancel | set_session_ptr |
| c00031 | 503ac5e4 | RSessionBase::Attach | session_send_eka1 |
| 000032 | 503ac5ec | RThread::Id | thread_id |
| 800033 | 503ac5f0 | TFindThread::Next | thread_find_next |
| c00034 | 503ac5f4 | RThread::Resume | thread_resume |
| c00035 | 503ac5f8 | RThread::Suspend | thread_suspend |
| 000036 | 503ac5fc | RThread::Priority | thread_priority |
| c00037 | 503ac600 | RThread::SetPriority | thread_set_priority_eka1 |
| 000038 | 503ac604 | RThread::ProcessPriority |  |
| c00039 | 503ac608 | RThread::SetProcessPriority | thread_set_process_priority_eka1 |
| 00003a | 503ac60c | RThread::Protected, RThread::System, UserSvr::BlockThreads |  |
| c0003b | 503ac610 | RThread::SetProtected, RThread::SetSystem, User::HandleException | thread_set_flags_eka1 |
| 00003c | 503ac614 | RThread::RequestCount | thread_request_count |
| 00003d | 503ac618 | RThread::ExitType | thread_exit_type |
| 00003e | 503ac61c | RThread::ExitReason |  |
| c0003f | 503ac620 | RThread::ExitCategory |  |
| 800040 | 503ac624 | RThread::GetDesLength | thread_get_des_length |
| 800041 | 503ac628 | RThread::GetDesMaxLength | thread_get_des_max_length |
| 800042 | 503ac62c | RThread::ReadL | thread_read_ipc_to_des8 |
| 800043 | 503ac630 | RThread::ReadL | thread_read_ipc_to_des16 |
| 800044 | 503ac634 | RThread::WriteL | thread_write_ipc_to_des8 |
| 800045 | 503ac638 | RThread::WriteL | thread_write_ipc_to_des16 |
| c00046 | 503ac63c | RThread::RequestComplete | thread_request_complete_eka1 |
| c00047 | 503ac640 | RTimer::Cancel | timer_cancel |
| c00048 | 503ac644 | RTimer::After | timer_after_eka1 |
| c00049 | 503ac648 | RTimer::At | timer_at_eka1 |
| c0004a | 503ac64c | RTimer::Lock | timer_lock_eka1 |
| 80004b | 503ac65c | RChangeNotifier::Logon | change_notifier_logon_eka1 |
| 80004c | 503ac660 | RChangeNotifier::LogonCancel | change_notifier_logoff |
| 00004d | 503ac664 | User::WaitForAnyRequest, User::WaitForRequest | wait_for_any_request |
| c0004e | 503ac668 | User::WaitForRequest | request_signal |
| 00004f | 503ac66c | User::Fold | uchar_fold |
| 000050 | 503ac670 | User::Collate |  |
| 000051 | 503ac674 | TChar::GetLowerCase, User::LowerCase | uchar_lowercase |
| 000052 | 503ac678 | TChar::GetUpperCase, User::UpperCase | uchar_uppercase |
| 000053 | 503ac67c | TChar::GetCategory, TChar::IsAlpha, TChar::IsAlphaDigit, TChar::IsAssigned ... | uchar_get_category |
| 800054 | 503ac680 | TDesC8::Match, TDesC8::MatchF | des8_match |
| 800055 | 503ac684 | TDesC16::Match, TDesC16::MatchF | des16_match |
| 800056 | 503ac7d4 | TDesC8::FindF | desc8_find |
| 800057 | 503ac7d8 | TDesC16::FindF | desc16_find |
| 800058 | 503ac7dc | TDesC8::LocateF | des8_locate_fold |
| 800059 | 503ac7e0 | TDesC16::LocateF | des16_locate_fold |
| 80005a | 503ac688 | RHandleBase::Name | handle_name_eka1 |
| 80005b | 503ac68c | RHandleBase::FullName |  |
| 80005c | 503ac690 | RHandleBase::HandleInfo | handle_info_eka1 |
| 80005d | 503ac694 | RThread::HandleCount |  |
| c0005e | 503ac698 | User::After | after |
| c0005f | 503ac69c | User::At |  |
| 800060 | 503ac6a0 | User::Language | user_language |
| 800061 | 503ac6a4 | TDayName::Set | locale_day_name_eka1 |
| 800062 | 503ac6a8 | TDayNameAbb::Set | locale_day_name_abb_eka1 |
| 800063 | 503ac6ac | TMonthName::Set | locale_month_name_eka1 |
| 800064 | 503ac6b0 | TMonthNameAbb::Set | locale_month_name_abb_eka1 |
| 800065 | 503ac6b4 | TDateSuffix::Set | locale_date_suffix_eka1 |
| 800066 | 503ac6b8 | TAmPmName::Set | locale_am_pm_eka1 |
| 800067 | 503ac6bc | TCurrencySymbol::Set |  |
| 800068 | 503ac6d4 | TLocale::Refresh | locale_refresh |
| c00069 | 503ac6d8 | TLocale::Set |  |
| c0006a | 503ac6dc | TLocaleMessageText::Set |  |
| c0006b | 503ac6e0 | RHandleBase::Close | message_complete_eka1 |
| 00006c | 503ac6e4 | User::Adjust, User::AdjustL, User::Alloc, User::AllocL ... | heap |
| c0006d | 503ac6e8 | User::SwitchHeap | heap_switch |
| 80006e | 503ac6ec | TTime::HomeTime, TTime::UniversalTime | time_now |
| c0006f | 503ac6f0 | User::SetHomeTime |  |
| 000070 | 503ac6f4 | User::TickCount | tick_count |
| 000071 | 503ac708 | User::LockPeriod |  |
| 000072 | 503ac6f8 | TTrap::Trap | push_trap_frame |
| 000073 | 503ac6fc | TTrap::UnTrap, User::Leave | pop_trap_frame |
| 000074 | 503ac700 | CActiveScheduler::Add, CActiveScheduler::Current, CActiveScheduler::Install, CActiveScheduler::Replace ... | active_scheduler |
| 000075 | 503ac704 | CActiveScheduler::Install, CActiveScheduler::Replace, _._16CActiveScheduler | set_active_scheduler |
| c00076 | 503ac70c | UserSvr::WsSwitchOnScreen | the_executor_eka1 |
| c00077 | 503ac710 | UserSvr::CaptureEventHook |  |
| c00078 | 503ac714 | UserSvr::ReleaseEventHook |  |
| c00079 | 503ac718 | UserSvr::RequestEvent |  |
| c0007a | 503ac71c | UserSvr::RequestEventCancel |  |
| c0007b | 503ac720 | UserSvr::AddEvent | add_event |
| 80007c | 503ac724 | UserSvr::ScreenInfo | user_svr_screen_info |
| 80007d | 503ac728 | UserSvr::DllGlobalAllocated | dll_global_data_allocated |
| 80007e | 503ac72c | UserSvr::DllGlobalRead | dll_global_data_read |
| 80007f | 503ac730 | UserSvr::DllGlobalWrite | dll_global_data_write |
| 000080 | 503ac734 | UserSvr::DllTls | dll_tls_eka1 |
| 000081 | 503ac740 | User::TrapHandler | trap_handler |
| 000082 | 503ac744 | User::SetTrapHandler | set_trap_handler |
| 800083 | 503ac748 | UserHal::CalibrationPoints, UserHal::DriveInfo, UserHal::ExceptionId, UserHal::ExceptionInfo ... | user_svr_hal_get |
| c00084 | 503ac74c | UserHal::RestoreXYInputCalibration, UserHal::SaveXYInputCalibration, UserHal::SetXYInputCalibration, UserHal::SwitchOff ... |  |
| 000085 | 503ac750 | UserSvr::KernelStartup |  |
| 000086 | 503ac754 | UserSvr::BlockThreads |  |
| c00087 | 503ac758 | UserSvr::WsRegisterThread |  |
| c00088 | 503ac75c | UserSvr::FsRegisterThread |  |
| c00089 | 503ac760 | User::Beep |  |
| 00008b | 503ac764 | User::JustInTime |  |
| 00008c | 503ac768 | User::SetJustInTime |  |
| 00008d | 503ac76c | User::LockedInc | locked_inc_32 |
| 00008e | 503ac770 | User::LockedDec | locked_dec_32 |
| 80008f | 503ac778 | TBusLocalDrive::Read |  |
| 800090 | 503ac77c | TBusLocalDrive::Write |  |
| 800091 | 503ac774 | TBusLocalDrive::Caps, TBusLocalDrive::Format |  |
| 800092 | 503ac780 | TBusLocalDrive::Format |  |
| 000093 | 503ac78c | User::SetDebugMask |  |
| c00097 | 503ac790 | RDebug::CancelGetException, RDebug::ClrBreakPoint, RDebug::ClrWatchPoint, RDebug::Continue ... | debug_command_execute |
| c00098 | 503ac794 |  |  |
| 000099 | 503ac798 | RDebug::ProfileStart |  |
| 00009a | 503ac79c | RDebug::ProfileEnd |  |
| 80009b | 503ac7a0 | Password::IsEnabled |  |
| 80009c | 503ac7a4 | Password::IsValid |  |
| 00009d | 503ac7a8 | User::FastCounter |  |
| 80009e | 503ac7ac | RThread::ExceptionHandler | exception_handler |
| c0009f | 503ac7b0 | RThread::SetExceptionHandler | set_exception_handler_eka1 |
| c000a0 | 503ac7b4 | RThread::ModifyExceptionMask |  |
| c000a1 | 503ac7b8 | RThread::RaiseException | raise_exception_eka1 |
| 8000a2 | 503ac7bc | RThread::IsExceptionHandled | is_exception_handled_eka1 |
| 8000a3 | 503ac7c4 | RThread::GetRamSizes |  |
| 8000a4 | 503ac7cc | RProcess::GetRamSizes |  |
| 8000a5 | 503ac7d0 | RLibrary::GetRamSizes |  |
| 8000a6 | 503ac7e4 | User::MachineConfiguration |  |
| 8000a7 | 503ac7e8 | UserSvr::TestBootSequence |  |
| 8000a8 | 503ac51c | User::Heap | heap_created |
| 8000a9 | 503ac54c | RLibrary::Type | library_type_eka1 |
| 8000aa | 503ac580 | RProcess::Type | process_type_eka1 |
| 8000ab | 503ac7ec | Mem::CollationMethodById, Mem::CollationMethodByIndex, Mem::CollationMethodId, Mem::CollationMethods ... | get_locale_char_set |
| 8000ac | 503ac7f0 | UserSvr::WsSwitchOnScreen |  |
| c000ad | 503ac7f8 | UserSvr::WsRegisterSwitchOnScreenHandling |  |
| 8000ae | 503ac6c0 | User::SetCurrencySymbol |  |
| 8000af | 503ac584 | RProcess::SetType | process_set_type_eka1 |
| 0000b0 | 503ac510 | RChunk::Bottom | chunk_bottom |
| 0000b1 | 503ac514 | RChunk::Top | chunk_top |
| 0000b2 | 503ac884 |  |  |
| 0000b3 | 503ac888 |  |  |
| 8000b5 | 503ac7c0 | RThread::Context |  |
| 8000b6 | 503ac73c |  |  |
| 8000b7 | 503ac544 | TFindLogicalChannel::Next | bus_dev_open_socket |
| 0000b8 | 503ac88c |  | user_svr_rom_root_dir_address |
| 8000b9 | 503ac7fc | RHandleBase::Attributes |  |
| 0000ba | 503ac548 | RBusLogicalChannel::DoControl |  |
| 8000bb | 503ac738 | UserSvr::DllFileName | user_svr_dll_filename |
| 0000bc | 503ac890 | User::IsRomAddress | user_svr_rom_header_address |
| 0000bd | 503ac894 |  |  |
| 0000be | 503ac800 | Math::Random | math_rand |
| c000bf | 503ac5e8 | RSessionBase::Attach | session_send_sync_eka1 |
| 8000c0 | 503ac59c | RProcess::CommandLineLength | process_command_line_length |
| c000c1 | 503ac650 | RTimer::Inactivity |  |
| 8000c2 | 503ac654 | User::InactivityTime | get_inactivity_time |
| 8000c3 | 503ac784 | TBusLocalDrive::ReadPasswordData |  |
| 8000c4 | 503ac788 | TBusLocalDrive::PasswordStoreLengthInBytes |  |
| 8000c5 | 503ac6c4 | TShortDateFormatSpec::Set |  |
| 8000c6 | 503ac6c8 | TLongDateFormatSpec::Set |  |
| 8000c7 | 503ac6cc | TTimeFormatSpec::Set |  |
| 0000c8 | 503ac6d0 | UserExec::FatUtilityFunctions |  |
| 8000c9 | 503ac658 | User::ResetInactivityTime | clear_inactivity_time |
| 8000ca | 503ac7c8 | RThread::GetCpuTime |  |
| 8000cb | 503ac7f4 | UserSvr::SetMemoryThresholds |  |
| 8000cc | 503ac804 | User::IMB_Range | imb_range |
| 8000cd | 503ac810 |  |  |
| 8000ce | 503ac814 |  |  |
| 8000cf | 503ac818 |  |  |
| 8000d0 | 503ac81c |  |  |
| 8000d1 | 503ac820 |  |  |
| 8000d2 | 503ac824 |  |  |
| 8000d3 | 503ac828 |  |  |
| 8000d4 | 503ac82c |  |  |
| 8000d5 | 503ac830 |  |  |
| 8000d6 | 503ac834 |  |  |
| 8000d7 | 503ac838 |  |  |
| 8000d8 | 503ac83c |  |  |
| 8000d9 | 503ac840 |  |  |
| 8000da | 503ac844 |  | property_subscribe |
| 8000dc | 503ac848 |  | property_find_get_int |
| 8000dd | 503ac84c |  |  |
| 8000de | 503ac850 |  |  |
| 8000df | 503ac854 |  | property_get_int |
| 8000e0 | 503ac858 |  |  |
| 8000e1 | 503ac85c |  |  |
| 8000e2 | 503ac860 |  | property_find_set_int |
| 8000e3 | 503ac864 |  |  |
| 8000e4 | 503ac868 |  | message_get_des_length |
| 8000e5 | 503ac86c |  | message_get_des_max_length |
| 8000e6 | 503ac870 |  | message_ipc_copy_eka1 |
| 8000e7 | 503ac874 |  |  |
| 8000e8 | 503ac878 |  |  |
| 8000e9 | 503ac87c |  |  |
| 8000ea | 503ac880 |  | message_queue_notify_space_available |
| 8000eb | 503ac808 |  | message_queue_notify_data_available |
| 8000ec | 503ac80c |  |  |
| b3ab16 | 503c0e38 |  |  |
