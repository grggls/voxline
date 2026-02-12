export const config = {
  port: parseInt(process.env.PORT || '3000', 10),
  nats: {
    url: process.env.NATS_URL || 'nats://nats.voxline.svc.cluster.local:4222',
  },
  mongodb: {
    url: process.env.MONGODB_URL || 'mongodb://mongodb.voxline.svc.cluster.local:27017/voxline',
  },
  redis: {
    url: process.env.REDIS_URL || 'redis://redis-master.voxline.svc.cluster.local:6379',
  },
};
