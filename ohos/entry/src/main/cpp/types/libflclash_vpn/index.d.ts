export const runCore: (endpoint: string) => Promise<void>;
export const startTun: (fd: number, options: string) => Promise<void>;
export const stopTun: () => Promise<void>;
export const stopCore: () => void;
export const takeOwners: () => string;
export const resolveOwner: (id: number, uid: number, bundle: string) => void;
