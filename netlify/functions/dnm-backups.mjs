import {createBackupHandler} from '../../server/backups-service.mjs';
// No keys/passwords are sent to browsers or logged.
export default createBackupHandler();
