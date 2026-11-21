#+build windows

package sdl3_file_drag

// Mock OLE consumer for the shared drag-out source. A real Explorer drag
// cannot be automated headlessly, so this fixture drives the exported
// IDataObject/IDropSource vtables exactly as a drop target would and checks the
// CF_HDROP payload, format negotiation, enumeration, and drag-cancel policy.

import "core:testing"
import alicorn "alicorn:runtime"
import win "core:sys/windows"

@(private)
file_drag_test_wide_path :: proc(t: ^testing.T, wide: [^]u16) -> string {
	if wide == nil { testing.expect(t, false, "CF_HDROP must carry a string"); return "" }
	length := 0
	for wide[length] != 0 { length += 1 }
	decoded, err := win.utf16_to_utf8(wide[:length], context.temp_allocator)
	if err != .None { testing.expectf(t, false, "CF_HDROP path must decode: %v", err); return "" }
	return decoded
}

@(test)
test_windows_file_drag_data_object_exposes_one_cf_hdrop :: proc(t: ^testing.T) {
	if i32(OleInitialize(nil)) < 0 {
		testing.expect(t, false, "OLE must initialize for the drag-out fixture")
		return
	}
	defer OleUninitialize()

	path := "C:\\alicorn\\dräge me.txt"
	object, created := windows_file_drag_object_create(path)
	if !created || object == nil {
		testing.expect(t, false, "the drag object should allocate for a unicode path")
		return
	}
	defer _ = win32_file_drag_release(rawptr(&object.data_object))

	data := &object.data_object
	vtable := cast(^Win32_IDataObject_VTable)data.vtable
	if vtable == nil { testing.expect(t, false, "IDataObject vtable must be installed"); return }

	// QueryInterface identifies both interfaces from the same object and
	// rejects unrelated IIDs without leaking a reference.
	result: rawptr
	testing.expect(t, vtable.query_interface(rawptr(data), &WIN32_IID_I_DATA_OBJECT, &result) == WIN32_S_OK &&
		result == rawptr(data), "QueryInterface(IID_IDataObject) returns the data object")
	_ = vtable.release(rawptr(data))
	testing.expect(t, vtable.query_interface(rawptr(data), &WIN32_IID_I_DROP_SOURCE, &result) == WIN32_S_OK &&
		result == rawptr(&object.drop_source), "QueryInterface(IID_IDropSource) returns the drop source")
	_ = win32_file_drag_release(rawptr(&object.drop_source))
	unknown_iid := win.GUID{0xDEADBEEF, 0, 0, {0, 0, 0, 0, 0, 0, 0, 0}}
	testing.expect(t, vtable.query_interface(rawptr(data), &unknown_iid, &result) == WIN32_E_NOINTERFACE &&
		result == nil, "an unrelated IID is rejected with E_NOINTERFACE")

	format := Win32_Format_Etc{
		cf_format=u16(win.CF_HDROP),
		dw_aspect=WIN32_DVASPECT_CONTENT,
		lindex=-1,
		tymed=WIN32_TYMED_HGLOBAL,
	}
	testing.expect(t, vtable.query_get_data(rawptr(data), &format) == WIN32_S_OK,
		"CF_HDROP/HGLOBAL/content/lindex=-1 is advertised")
	wrong_format := format
	wrong_format.cf_format = u16(win.CF_UNICODETEXT)
	testing.expect(t, vtable.query_get_data(rawptr(data), &wrong_format) == WIN32_DV_E_FORMATETC,
		"an unsupported clipboard format is rejected")
	wrong_aspect := format
	wrong_aspect.dw_aspect = 2
	testing.expect(t, vtable.query_get_data(rawptr(data), &wrong_aspect) == WIN32_DV_E_FORMATETC,
		"a non-content aspect is rejected")
	wrong_index := format
	wrong_index.lindex = 0
	testing.expect(t, vtable.query_get_data(rawptr(data), &wrong_index) == WIN32_DV_E_FORMATETC,
		"only the whole-item index (-1) is served")
	wrong_tymed := format
	wrong_tymed.tymed = 2
	testing.expect(t, vtable.query_get_data(rawptr(data), &wrong_tymed) == WIN32_DV_E_TYMED,
		"a non-HGLOBAL medium is rejected with DV_E_TYMED")

	medium: Win32_Stg_Medium
	testing.expect(t, vtable.get_data(rawptr(data), &format, &medium) == WIN32_S_OK &&
		medium.tymed == WIN32_TYMED_HGLOBAL && medium.contents.h_global != win.HGLOBAL(nil),
		"GetData yields one HGLOBAL medium")
	if medium.contents.h_global != win.HGLOBAL(nil) {
		locked := win.GlobalLock(medium.contents.h_global)
		if locked == nil {
			testing.expect(t, false, "the CF_HDROP HGLOBAL must be lockable")
		} else {
			header := cast(^Win32_Drop_Files)(locked)
			testing.expect(t, header.p_files == u32(size_of(Win32_Drop_Files)) && header.f_wide == win.BOOL(true) &&
				header.f_nc == win.BOOL(false),
				"DROPFILES names a wide, non-client-relative payload")
			wide := cast([^]u16)(cast(uintptr)(locked)+uintptr(size_of(Win32_Drop_Files)))
			testing.expect(t, file_drag_test_wide_path(t, wide) == path,
				"the offered file name round-trips exactly, including non-ASCII text")
			_ = win.GlobalUnlock(medium.contents.h_global)
		}
		_ = win.GlobalFree(cast(win.LPVOID)medium.contents.h_global)
	}

	// Directory paths use the same CF_HDROP contract.
	directory, directory_created := windows_file_drag_object_create("C:\\alicorn\\folder")
	if directory_created {
		directory_data := &directory.data_object
		directory_vtable := cast(^Win32_IDataObject_VTable)directory_data.vtable
		directory_medium: Win32_Stg_Medium
		testing.expect(t, directory_vtable.get_data(rawptr(directory_data), &format, &directory_medium) == WIN32_S_OK,
			"a folder path is exported through the same format")
		if directory_medium.contents.h_global != win.HGLOBAL(nil) {
			locked := win.GlobalLock(directory_medium.contents.h_global)
			if locked != nil {
				wide := cast([^]u16)(cast(uintptr)(locked)+uintptr(size_of(Win32_Drop_Files)))
				testing.expect(t, file_drag_test_wide_path(t, wide) == "C:\\alicorn\\folder",
					"the offered folder name round-trips exactly")
				_ = win.GlobalUnlock(directory_medium.contents.h_global)
			}
			_ = win.GlobalFree(cast(win.LPVOID)directory_medium.contents.h_global)
		}
		_ = win32_file_drag_release(rawptr(directory_data))
	} else {
		testing.expect(t, false, "the drag object should allocate for a folder path")
	}

	// EnumFORMATETC advertises exactly the one supported format.
	enumerator: ^Win32_IEnum_Format_Etc
	testing.expect(t, vtable.enum_format_etc(rawptr(data), WIN32_DATADIR_GET, &enumerator) == WIN32_S_OK &&
		enumerator != nil, "EnumFormatEtc(DATADIR_GET) returns an enumerator")
	if enumerator != nil {
		enum_vtable := enumerator.vtable
		items: Win32_Format_Etc
		fetched: u32
		testing.expect(t, enum_vtable.next(enumerator, 1, &items, &fetched) == WIN32_S_OK && fetched == 1 &&
			items.cf_format == u16(win.CF_HDROP) && items.dw_aspect == WIN32_DVASPECT_CONTENT &&
			items.lindex == -1 && items.tymed == WIN32_TYMED_HGLOBAL,
			"the enumerator yields the CF_HDROP format")
		testing.expect(t, enum_vtable.next(enumerator, 1, &items, &fetched) == WIN32_S_FALSE && fetched == 0,
			"the enumerator ends after one format")
		testing.expect(t, enum_vtable.reset(enumerator) == WIN32_S_OK &&
			enum_vtable.next(enumerator, 1, &items, &fetched) == WIN32_S_OK,
			"reset makes the single format enumerable again")
		_ = enum_vtable.release(enumerator)
	}

	// Unsupported IDataObject members stay explicit rather than pretending to
	// accept data or advise sinks.
	here_medium: Win32_Stg_Medium
	testing.expect(t, vtable.get_data_here(rawptr(data), &format, &here_medium) == WIN32_E_NOTIMPL,
		"GetDataHere is not implemented")
	set_medium: Win32_Stg_Medium
	testing.expect(t, vtable.set_data(rawptr(data), &format, &set_medium, win.BOOL(false)) == WIN32_E_NOTIMPL,
		"SetData is not implemented")
	connection: u32
	testing.expect(t, vtable.d_advise(rawptr(data), &format, 0, nil, &connection) == WIN32_OLE_E_ADVISENOTSUPPORTED,
		"DAdvise reports no advise support")
}

@(test)
test_windows_file_drag_drop_source_cancels_escapes_and_drops_on_release :: proc(t: ^testing.T) {
	object, created := windows_file_drag_object_create("C:\\alicorn\\drop-source.txt")
	if !created || object == nil {
		testing.expect(t, false, "the drop source object should allocate")
		return
	}
	defer _ = win32_file_drag_release(rawptr(&object.data_object))

	source := &object.drop_source
	vtable := cast(^Win32_IDropSource_VTable)source.vtable
	if vtable == nil { testing.expect(t, false, "IDropSource vtable must be installed"); return }
	testing.expect(t, vtable.query_continue_drag(rawptr(source), win.BOOL(true), WIN32_MK_LBUTTON) == WIN32_DRAGDROP_S_CANCEL,
		"Escape cancels the drag even while the button is held")
	testing.expect(t, vtable.query_continue_drag(rawptr(source), win.BOOL(false), WIN32_MK_LBUTTON) == WIN32_S_OK,
		"a held left button continues the drag")
	testing.expect(t, vtable.query_continue_drag(rawptr(source), win.BOOL(false), 0) == WIN32_DRAGDROP_S_DROP,
		"releasing the left button drops")
	testing.expect(t, vtable.give_feedback(rawptr(source), WIN32_DROPEFFECT_COPY) == WIN32_DRAGDROP_S_USEDEFAULTCURSORS,
		"the source requests the default OLE cursors")
}

@(test)
test_windows_file_drag_start_rejects_unsupported_paths :: proc(t: ^testing.T) {
	service := service()
	testing.expect(t, service.start != nil, "the Windows host publishes a native drag source")
	testing.expect(t, !is_active(), "the modal-drag guard is clear outside DoDragDrop")
	testing.expect(t, !alicorn.application_file_drag_start(service, ""), "an empty path is rejected before OLE")
	testing.expect(t, !alicorn.application_file_drag_start(service, "C:\\bad\\zero\x00byte.txt"),
		"an embedded NUL is rejected before OLE")
}
