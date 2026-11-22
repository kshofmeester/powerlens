package collect

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdint.h>

#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_KEYINFO 9
#define KERNEL_INDEX_SMC     2

typedef struct {
	uint8_t  major;
	uint8_t  minor;
	uint8_t  build;
	uint8_t  reserved;
	uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
	uint16_t version;
	uint16_t length;
	uint32_t cpuPLimit;
	uint32_t gpuPLimit;
	uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
	uint32_t dataSize;
	uint32_t dataType;
	uint8_t  dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
	uint32_t                 key;
	SMCKeyData_vers_t        vers;
	SMCKeyData_pLimitData_t  pLimitData;
	SMCKeyData_keyInfo_t     keyInfo;
	uint8_t                  result;
	uint8_t                  status;
	uint8_t                  data8;
	uint32_t                 data32;
	uint8_t                  bytes[32];
} SMCKeyData_t;

static uint32_t smcKey(const char *s) {
	return ((uint32_t)(uint8_t)s[0] << 24)
	     | ((uint32_t)(uint8_t)s[1] << 16)
	     | ((uint32_t)(uint8_t)s[2] <<  8)
	     | ((uint32_t)(uint8_t)s[3]);
}

static kern_return_t smcCall(io_connect_t conn, int idx,
                              SMCKeyData_t *in, SMCKeyData_t *out) {
	size_t inSz = sizeof(SMCKeyData_t), outSz = sizeof(SMCKeyData_t);
	return IOConnectCallStructMethod(conn, idx, in, inSz, out, &outSz);
}

// getCPUDieTemp opens the SMC and averages valid CPU core temperatures
// across Apple Silicon (flt ) or Intel (sp78) keys, returning °C or -1.0.
double getCPUDieTemp() {
	io_iterator_t iter = 0;
	io_object_t   svc  = 0;
	io_connect_t  conn = 0;
	double        temp = -1.0;

	CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
	if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess)
		return -1.0;

	svc = IOIteratorNext(iter);
	IOObjectRelease(iter);
	if (!svc) return -1.0;

	if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
		IOObjectRelease(svc);
		return -1.0;
	}
	IOObjectRelease(svc);

	// flt : IEEE 754 float32, 4 bytes little-endian (Apple Silicon)
	// sp78: signed fixed-point 8.8, 2 bytes big-endian → divide by 256 (Intel)
	uint32_t flt  = ((uint32_t)'f' << 24) | ((uint32_t)'l' << 16)
	              | ((uint32_t)'t' <<  8) | (uint32_t)' ';
	uint32_t sp78 = ((uint32_t)'s' << 24) | ((uint32_t)'p' << 16)
	              | ((uint32_t)'7' <<  8) | (uint32_t)'8';

	const char *m3Keys[] = {
		"Te05", "Te0L", "Te0P", "Te0S",
		"Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
		"Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
		NULL
	};
	const char *m12Keys[] = {
		"Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
		NULL
	};
	const char *intelKeys[] = {"TC0D", "TC0P", "TC0F", NULL};
	const char **groups[]   = {m3Keys, m12Keys, intelKeys, NULL};

	for (int g = 0; groups[g] && temp < 0; g++) {
		double sum = 0.0;
		int count  = 0;

		for (int k = 0; groups[g][k]; k++) {
			SMCKeyData_t in = {0}, out = {0};
			in.key   = smcKey(groups[g][k]);
			in.data8 = SMC_CMD_READ_KEYINFO;
			if (smcCall(conn, KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) continue;

			int isFlt  = (out.keyInfo.dataType == flt  && out.keyInfo.dataSize == 4);
			int isSp78 = (out.keyInfo.dataType == sp78 && out.keyInfo.dataSize >= 2);
			if (!isFlt && !isSp78) continue;

			SMCKeyData_t in2 = {0}, out2 = {0};
			in2.key              = in.key;
			in2.keyInfo.dataSize = out.keyInfo.dataSize;
			in2.data8            = SMC_CMD_READ_BYTES;
			if (smcCall(conn, KERNEL_INDEX_SMC, &in2, &out2) != kIOReturnSuccess) continue;

			double val = -1.0;
			if (isFlt) {
				union { uint8_t b[4]; float f; } u;
				u.b[0] = (uint8_t)out2.bytes[0];
				u.b[1] = (uint8_t)out2.bytes[1];
				u.b[2] = (uint8_t)out2.bytes[2];
				u.b[3] = (uint8_t)out2.bytes[3];
				val = (double)u.f;
			} else {
				int16_t raw = (int16_t)(((uint8_t)out2.bytes[0] << 8) | (uint8_t)out2.bytes[1]);
				val = (double)raw / 256.0;
			}

			// Reject NaN and idle-core 0–6°C readings
			if (val > 10.0 && val < 120.0) {
				sum += val;
				count++;
			}
		}

		if (count > 0) {
			temp = sum / (double)count;
		}
	}

	IOServiceClose(conn);
	return temp;
}
*/
import "C"
import (
	"strconv"
	"strings"
)

// getSMCTemp reads CPU die temperature from the SMC (Intel path).
func getSMCTemp() float64 {
	return float64(C.getCPUDieTemp())
}

// parsePowermetricsTemp extracts cpu_die_temperature_celsius from a
// powermetrics plist string (Apple Silicon path). Returns -1 if absent.
func parsePowermetricsTemp(plist string) float64 {
	for _, line := range strings.Split(plist, "\n") {
		if strings.Contains(line, "cpu_die_temperature_celsius") {
			start := strings.Index(line, "<real>")
			end := strings.Index(line, "</real>")
			if start >= 0 && end > start {
				valStr := line[start+len("<real>") : end]
				if v, err := strconv.ParseFloat(strings.TrimSpace(valStr), 64); err == nil {
					return v
				}
			}
		}
	}
	return -1
}

// GetCPUTemp returns the CPU die temperature in °C.
// plist is the powermetrics output string (non-empty on Apple Silicon);
// if empty or the key is missing, falls back to a direct SMC read (Intel).
// Returns -1 if temperature cannot be determined.
func GetCPUTemp(plist string) float64 {
	if plist != "" {
		if t := parsePowermetricsTemp(plist); t >= 0 {
			return t
		}
	}
	return getSMCTemp()
}
