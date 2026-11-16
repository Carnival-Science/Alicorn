package alicorn_sdl_gpu

import alicorn "../../runtime"
import "vendor:sdl3"
import sdl_host "alicorn:host/sdl3"

native_context_menu_key_from_sdl :: proc(key: sdl3.Keycode) -> alicorn.Context_Menu_Key {
	return sdl_host.context_menu_key_from_sdl(key)
}
