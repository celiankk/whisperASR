#ifndef TRANSCRIBE_SHIM_H
#define TRANSCRIBE_SHIM_H

#include "transcribe.h"

/* Opaque session pointer as a concrete typedef, so Swift imports it as
 * OpaquePointer instead of an incomplete struct type. */
typedef struct transcribe_session * transcribe_session_ref;

transcribe_status transcribe_open_swift(const char * path, transcribe_session_ref * out_session);
transcribe_status transcribe_run_swift(transcribe_session_ref session, const float * pcm, int n_samples);
const char * transcribe_full_text_swift(transcribe_session_ref session);
void transcribe_close_swift(transcribe_session_ref session);

#endif
