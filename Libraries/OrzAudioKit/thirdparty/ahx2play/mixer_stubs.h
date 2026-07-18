static inline void lockMixer(void) {}
static inline void unlockMixer(void) {}
static inline int openMixer(int freq, int bufsize) { (void)freq; (void)bufsize; return 1; }
static inline void closeMixer(void) {}
