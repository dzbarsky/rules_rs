#![no_std]
extern crate alloc;

use alloc::vec::Vec;
use core::{arch::wasm32, slice, str};

use dlmalloc::GlobalDlmalloc;

// Provide a global allocator so `Vec`/`String` work on wasm32-unknown-unknown.
#[global_allocator]
static ALLOC: GlobalDlmalloc = GlobalDlmalloc;

const PAGE_SIZE: u32 = 65536;

// Exported allocator that mirrors your WAT semantics:
// - Grows memory by ceil(size / 65536) pages.
// - Returns old heap size IN BYTES on success; 0 on failure.
// - `align` is accepted but ignored (to match your WAT).
#[unsafe(no_mangle)]
pub extern "C" fn allocate(size: u32, _align: u32) -> u32 {
    let extra_pages = (size / PAGE_SIZE) + if size % PAGE_SIZE != 0 { 1 } else { 0 };
    let prev_pages = wasm32::memory_grow(0, extra_pages as usize);
    if prev_pages == usize::MAX {
        0
    } else {
        (prev_pages as u32) * PAGE_SIZE
    }
}

// Helper: write a byte slice to a freshly allocated region using `allocate`,
// then store its pointer/len at the given output addrs.
fn write_out(buf: &[u8], output_ptr_ptr: u32, output_len_ptr: u32) {
    // Record length
    unsafe { (output_len_ptr as *mut u32).write_unaligned(buf.len() as u32); }

    if buf.is_empty() {
        unsafe {(output_ptr_ptr as *mut u32).write_unaligned(0);}
        return;
    }

    // Allocate exact size (we rely on `allocate`’s page-granularity and just use the start)
    let out_ptr = allocate(buf.len() as u32, 1);
    unsafe {(output_ptr_ptr as *mut u32).write_unaligned(out_ptr);}

    // Copy bytes
    let dst = unsafe {slice::from_raw_parts_mut(out_ptr as *mut u8, buf.len())};
    dst.copy_from_slice(buf);
}

// Exported entrypoint: parse TOML text in [input_ptr, input_ptr+input_len),
// serialize to JSON, write to a newly-allocated buffer, and return status:
//
// 0 = success
// 1 = input was not valid UTF-8
// 2 = TOML parse error
// 3 = JSON serialization error (unlikely here)
//
// On error, we also return a UTF-8 error message in the output buffer.
#[unsafe(no_mangle)]
pub extern "C" fn toml2json(
    input_ptr: u32,
    input_len: u32,
    output_ptr_ptr: u32,
    output_len_ptr: u32,
) -> u32 {
    unsafe {
        let input_bytes = slice::from_raw_parts(input_ptr as *const u8, input_len as usize);

        let input_str = match str::from_utf8(input_bytes) {
            Ok(s) => s,
            Err(e) => {
                let msg = alloc::format!("utf8 error: {}", e);
                write_out(msg.as_bytes(), output_ptr_ptr, output_len_ptr);
                return 1;
            }
        };

        // Serialize that value as JSON text
        let mut out = Vec::with_capacity((input_len as usize).saturating_mul(6) / 5);
        let mut ser = serde_json::Serializer::new(&mut out);
        let de =  toml::de::Deserializer::new(input_str);
        match serde_transcode::transcode(de, &mut ser) {
            Ok(()) => {
                write_out(&out, output_ptr_ptr, output_len_ptr);
                0
            }
            Err(e) => {
                // `toml::de::Error` for parse failures OR serde/transcode issues
                let msg = alloc::format!("toml parse/transcode error: {}", e);
                write_out(msg.as_bytes(), output_ptr_ptr, output_len_ptr);
                2
            }
        }
    }
}
