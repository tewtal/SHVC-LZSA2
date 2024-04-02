; LZSA2 decompressor for SNES
; by total <total@viskos.org>

; Specifically targeting and optimized for ROM -> WRAM copies
; Based on SHVC-LZSA2 by David Lindecrantz <optiroc@me.com>


; !lzsa_vars = $39
; lz_token = !lzsa_vars
; lz_nibrdy = !lzsa_vars+1
; lz_nibble = !lzsa_vars+2
; lz_temp = !lzsa_vars+5
; lz_mvl = !lzsa_vars+7
; lz_mvm = !lzsa_vars+11
; lz_match = !lzsa_vars+15

lz_mvl = $804307
lz_mvm = $804317
lz_token = $804367
lz_nibrdy = $804368
lz_nibble = $804369
lz_temp = $804362
lz_match = $80436a

macro readByte()
?readByte:
    lda.w $0000, X
    inx
    bne ?.noWrap
    pha : phb : pla : inc : pha : plb : pla
    ldx #$8000
    inc.b lz_mvl+2
?.noWrap
endmacro

macro writeByte()
    sta.l $002180
    iny
endmacro

macro writeWord()
    sep #$20
    sta.l $002180
    xba
    sta.l $002180
    iny #2
endmacro

macro readWord()
?readWord:
    cpx #$fffe
    bcc ?.noWrap
    beq ?.evenWrap
    sep #$20
    %readByte()
    xba
    %readByte()
    xba
    rep #$20
    bra ?.done
?.evenWrap
    rep #$20
    lda.w $0000, x
    pha : phb : pla : inc : pha : plb : pla
    ldx #$8000
    inc.b lz_mvl+2
    bra ?.done
?.noWrap
    rep #$20
    lda.w $0000, X
    inx #2
?.done
endmacro


macro readNibble()
?readNibble:
    lsr.b lz_nibrdy
    bcs ?.ready
    %readByte()
    inc.b lz_nibrdy
    sta.b lz_nibble
    lsr #4
    bra ?.done
?.ready
    lda.b lz_nibble
    and.b #$0f
?.done
endmacro

; Decompress LZSA2 block
;
; Parameters (a8i16):
;   x           Source offset
;   y           Destination offset
;   b:a         Destination:Source banks

lzsa2_decomp:
    php
    phb

    phd
    rep #$20
    pha
    lda #$4300              ; Set direct page at CPU MMIO area
    tcd
    pla

    sep #$20
    sta.b lz_mvl+$2
    sta.b $64
    pha : plb

    lda.b #$54
    sta.b lz_mvl
    sta.b lz_mvm

    lda.b #$60
    sta.b lz_mvl+$3
    sta.b lz_mvm+$3

    xba
    sta.b lz_mvl+$1
    sta.b lz_mvm+$1
    sta.b lz_mvm+$2
    and.b #$01
    sta.l $002183

    rep #$20
    tya : sta.l $002181
    sep #$20

    stz.b lz_nibrdy
    stz.b lz_nibble

    ; Setup DMA channel 6 for A-B copies from ROM to WRAM
    stz.b $60
    lda.b #$80
    sta.b $61

.readToken
    %readByte()
    sta.b lz_token
    and.b #$18
    bne +
    jmp .match
+
    cmp.b #$10
    beq .litWord
    bpl .extLit

    %readByte()
    %writeByte()
    jmp .match

.litWord
    %readWord()
    %writeWord()
    jmp .match
.extLit
    %readNibble()
    cmp.b #$0f
    beq .litByteLen
    clc : adc.b #$03
    bra .litCopy
.litByteLen
    %readByte()
    cmp.b #$ef
    beq .litWordLen
    clc : adc.b #$12
    bra .litCopy
.litWordLen
    %readWord()
    bra .litCopyWord
.litCopy
    rep #$20
    and.w #$00ff
.litCopyWord

    ; Length in A
    ; Source address in X
    ; Target address in Y
    pha

    stx.b lz_temp
    clc : adc.b lz_temp
    bmi .noLitWrap

    pha ; A = remaining bytes after wrap
    lda.w #$ffff
    sec : sbc.b lz_temp
    
    sta.b $65
    tya : clc : adc.b $65 : tay
    
    sep #$20
    lda.b #$40 : sta.l $00420b

    inc.b lz_mvl+2
    rep #$20

    pla : tax : pla : phx
    ldx #$8000

.noLitWrap
    pla

    sta.b $65
    tya : clc : adc.b $65 : tay

    sep #$20
    lda.b #$40 : sta.l $00420b
    ldx.b $62

.match
    lda.b lz_token
    asl
    bcs .matchLong
    asl
    bcs .match01Z

; 00Z 5-bit offset:
; - Read a nibble for offset bits 1-4 and use the inverted bit Z of the token as bit 0 of the offset.
; - Set bits 5-15 of the offset to 1.
.match00Z
    asl
    php
    %readNibble()
    plp
    rol
    eor.b #%11100001
    xba
    lda.b #$ff
    xba
    rep #$20
    jmp .matchLen

; 01Z 9-bit offset:
; Read a byte for offset bits 0-7 and use the inverted bit Z for bit 8 of the offset.
; Set bits 9-15 of the offset to 1.
.match01Z
    asl                     ; Shift Z to C
    php
    %readByte()
    xba
    plp
    lda.b #$00
    rol
    eor.b #$ff
    xba
    rep #$20
    jmp .matchLen

.matchLong
    asl                     ; Shift Y to C, Z to N
    bcc .match10Z
    bmi .match111

; 110 16-bit offset:
; Read a byte for offset bits 8-15, then another byte for offset bits 0-7.
.match110
    %readWord()
    xba
    bra .matchLen

; 111 Repeat previous offset
.match111
    rep #$20
    lda.b lz_match
    bra .matchLen

; 10Z 13-bit offset:
; Read a nibble for offset bits 9-12 and use the inverted bit Z for bit 8 of the offset, then read a byte for offset bits 0-7.
; Set bits 13-15 of the offset to 1. Subtract 512 from the offset to get the final value.
.match10Z:
    asl                     ; Shift Z to C
    php
    %readNibble()
    plp
    rol                     ; Shift nibble, Z into bit 0, C = 0
    eor.b #%11100001
    dec
    dec
    xba
    %readByte()
    rep #$20

.matchLen:
    sta.b lz_match
    sep #$20

    lda.b lz_token
    and.b #$07
    cmp.b #$07
    beq .extMatchLen
    inc
    jmp .copyMatch

.extMatchLen
    %readNibble()
    cmp.b #$0f
    beq .extMatchByteLen
    clc : adc.b #$08
    bra .copyMatch

.extMatchByteLen
    %readByte()
    cmp.b #$e8
    beq .done
    bcs .extMatchWordLen
    clc : adc.b #$17
    bra .copyMatch

.extMatchWordLen
    %readWord()
    dec
    bra .copyMatchWord

.copyMatch
    rep #$20
    and #$00ff

.copyMatchWord
    ; Length in A
    ; Source address lz_match
    ; Target address in Y
    phx
    pha

    tya
    clc : adc.b lz_match
    tax
    
    pla

    phb
    jsr.w lz_mvm
    plb

    plx
    tya : sta.l $002181
    sep #$20

    jmp .readToken

.done
    pld
    plb
    plp
    rtl