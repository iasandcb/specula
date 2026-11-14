package com.ias.specula

import java.io.*
import java.net.*
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

data class Frame(val width: Int, val height: Int, val rgba: ByteArray)

/** Blocking protocol engine: caller runs it on Dispatchers.IO. Only writes are shared. */
class RfbClient : Closeable {
    @Volatile private var socket: Socket? = null
    private var output: OutputStream? = null
    private val writeLock = Any()
    @Volatile var width = 0; private set
    @Volatile var height = 0; private set
    private var pixels = ByteArray(0)
    fun send(bytes: ByteArray) = synchronized(writeLock) {
        (output ?: throw IOException("연결이 종료되었습니다.")).apply { write(bytes); flush() }
    }
    fun key(symbol: Int, down: Boolean) = send(Wire.key(symbol,down))
    fun pointer(x: Int,y: Int,buttons: Int) {
        if(width>0 && height>0) send(Wire.pointer(x.coerceIn(0,width-1),y.coerceIn(0,height-1),buttons))
    }
    fun request(incremental: Boolean) = send(Wire.packet { writeByte(3); writeByte(if(incremental) 1 else 0); writeShort(0); writeShort(0); writeShort(width); writeShort(height) })
    fun run(host: String, username: String, password: String, port: Int = 5900, onReady: (String)->Unit = {}, onFrame: (Frame)->Unit) {
        val conn=Socket(); socket=conn
        val timer=Executors.newSingleThreadScheduledExecutor()
        val deadline=timer.schedule({ conn.close() },45,TimeUnit.SECONDS)
        try {
            conn.tcpNoDelay=true; conn.keepAlive=true; conn.connect(InetSocketAddress(host,port),5000); conn.soTimeout=10000
            output=conn.getOutputStream()
            val input=DataInputStream(BufferedInputStream(conn.getInputStream()))
            fun bytes(n: Int)=ByteArray(n).also(input::readFully)
            fun reason(): String { val n=input.readInt(); requireProtocol(n in 0..1048576,"서버 메시지가 너무 큽니다."); return bytes(n).toString(Charsets.UTF_8) }
            val banner=bytes(12).toString(Charsets.US_ASCII)
            requireProtocol(Regex("RFB 003\\.[0-9]{3}\\n").matches(banner),"지원하지 않는 화면 공유 프로토콜입니다.")
            val minor=banner.substring(8,11).toInt(); requireProtocol(minor>=3)
            val version=if(minor>=8) 8 else if(minor>=7) 7 else 3
            send("RFB 003.00$version\n".toByteArray())
            val security=if(username.isNotEmpty()) 30 else 2
            if(version==3) requireProtocol(input.readInt()==security,"맥의 화면 공유 로그인 설정을 확인해 주세요.") else {
                val n=input.readUnsignedByte(); requireProtocol(n>0,if(n==0) reason() else "인증 방식 오류")
                requireProtocol(security.toByte() in bytes(n),"맥 사용자 이름·암호 또는 VNC 암호 설정을 확인해 주세요.")
                send(byteArrayOf(security.toByte()))
            }
            if(security==30) {
                val generator=input.readUnsignedShort(); val n=input.readUnsignedShort()
                requireProtocol(n in 128..512,"지원하지 않는 맥 인증 키 크기입니다.")
                send(ARD.response(generator,bytes(n),bytes(n),username,password))
            } else send(Wire.challenge(bytes(16),password))
            requireProtocol(input.readInt()==0,"맥 인증에 실패했습니다. 사용자 이름·암호와 화면 공유 접근 권한을 확인해 주세요.")
            send(byteArrayOf(1)); width=input.readUnsignedShort(); height=input.readUnsignedShort(); bytes(16)
            val name=reason(); allocate()
            send(byteArrayOf(0,0,0,0)+Wire.format); send(Wire.encodings)
            deadline.cancel(false); timer.shutdown(); conn.soTimeout=0
            onReady(name); request(false)
            ZRLE().use { zrle ->
                while(!conn.isClosed) when(val type=input.readUnsignedByte()) {
                    0 -> { val changed=readUpdate(input,zrle); if(changed) onFrame(Frame(width,height,pixels.copyOf())) }
                    2 -> Unit
                    3 -> { bytes(3); reason() }
                    else -> throw IOException("지원하지 않는 서버 메시지입니다: $type")
                }
            }
        } finally { deadline.cancel(false); timer.shutdownNow(); conn.close(); synchronized(writeLock) { output=null }; socket=null }
    }
    private fun allocate() { FrameLimits.check(width,height); pixels=ByteArray(width*height*4) }
    /** Shared by live socket and replay tests; caller has consumed message type 0. */
    internal fun readUpdate(input: DataInputStream, zrle: ZRLE): Boolean {
        input.readUnsignedByte(); val count=input.readUnsignedShort(); var resized=false; var changed=false
        repeat(count) {
            val x=input.readUnsignedShort(); val y=input.readUnsignedShort(); val w=input.readUnsignedShort(); val h=input.readUnsignedShort(); val encoding=input.readInt()
            if(encoding==-224) { if(output!=null) request(!resized); return changed }
            try {
                if(encoding==-223) { width=w; height=h; allocate(); resized=true; changed=true; return@repeat }
                FrameLimits.check(w,h); requireProtocol(x+w<=width && y+h<=height)
                val data=when(encoding) {
                    0 -> ByteArray(w*h*4).also { input.readFully(it); for(i in 3 until it.size step 4) it[i]=-1 }
                    1 -> {
                        val sx=input.readUnsignedShort(); val sy=input.readUnsignedShort()
                        requireProtocol(sx+w<=width && sy+h<=height,"화면 복사 범위가 잘못되었습니다.")
                        ByteArray(w*h*4).also { copy -> repeat(h) { row -> pixels.copyInto(copy,row*w*4,((sy+row)*width+sx)*4,((sy+row)*width+sx+w)*4) } }
                    }
                    16 -> {
                        val n=input.readInt(); requireProtocol(n in 1..FrameLimits.compressed(w,h),"화면 압축 크기가 잘못되었습니다.")
                        zrle.compressed(w,h,ByteArray(n).also(input::readFully))
                    }
                    else -> throw IOException("지원하지 않는 화면 압축 방식입니다: $encoding")
                }
                repeat(h) { row -> data.copyInto(pixels,((y+row)*width+x)*4,row*w*4,(row+1)*w*4) }; changed=true
            } catch(e: Exception) { throw IOException("화면 데이터 오류 · 인코딩 $encoding · $x,$y ${w}×$h: ${e.message}",e) }
        }
        if(output!=null) request(!resized)
        return changed
    }
    internal fun initReplay(w: Int,h: Int) { width=w; height=h; allocate() }
    internal fun frame() = Frame(width,height,pixels.copyOf())
    override fun close() { socket?.close() }
}
